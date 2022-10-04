# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch accounts stapshot
## =======================
##
## Worker items state diagram:
## ::
##   unprocessed slot requests | peer workers + storages database update
##   ===================================================================
##
##        +-----------------------------------------------+
##        |                                               |
##        v                                               |
##   <unprocessed> ------------+-------> <worker-0> ------+
##                             |                          |
##                             +-------> <worker-1> ------+
##                             |                          |
##                             +-------> <worker-2> ------+
##                             :                          :
##

import
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/keyed_queue,
  stint,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_storage_ranges],
  ./snap_db

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getNextSlotItem(buddy: SnapBuddyRef): Result[SnapSlotQueueItemRef,void] =
  let env = buddy.data.pivotEnv
  for w in env.leftOver.nextKeys:
    # Make sure that this item was not fetched and rejected earlier
    if w notin buddy.data.vetoSlots:
      env.leftOver.del(w)
      return ok(w)
  err()

proc fetchAndImportStorageSlots(
    buddy: SnapBuddyRef;
    reqSpecs: seq[AccountSlotsHeader];
      ): Future[Result[seq[SnapSlotQueueItemRef],ComError]]
      {.async.} =
  ## Fetch storage slots data from the network, store it on disk and
  ## return data to process in the next cycle.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Get storage slots
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, reqSpecs)
    if rc.isErr:
      return err(rc.error)
    rc.value

  if 0 < stoRange.data.storages.len:
    # Verify/process data and save to disk
    block:
      let rc = ctx.data.snapDb.importStorages(peer, stoRange.data)

      if rc.isErr:
        # Push back parts of the error item
        var once = false
        for w in rc.error:
          if 0 <= w[0]:
            # Reset any partial requests by not copying the `firstSlot` field.
            # So all the storage slots are re-fetched completely for this
            # account.
            stoRange.addLeftOver(
              @[AccountSlotsHeader(
                accHash:     stoRange.data.storages[w[0]].account.accHash,
                storageRoot: stoRange.data.storages[w[0]].account.storageRoot)],
              forceNew = not once)
            once = true
        # Do not ask for the same entries again on this `peer`
        if once:
          buddy.data.vetoSlots.incl stoRange.leftOver[^1]

        if rc.error[^1][0] < 0:
          discard
          # TODO: disk storage failed or something else happend, so what?

  # Return the remaining part to be processed later
  return ok(stoRange.leftOver)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc storeStorages*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch account storage slots and store them in the database.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
  var
    once = true # for logging

  # Fetch storage data and save it on disk. Storage requests are managed by
  # a request queue for handling partioal replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.
  while true:
    # Pull out the next request item from the queue
    let req = block:
      let rc = buddy.getNextSlotItem()
      if rc.isErr:
        return # currently nothing to do
      rc.value

    when extraTraceMessages:
      if once:
        once = false
        trace "Start fetching storage slotss", peer,
          nAccounts=(1+env.leftOver.len), nVetoSlots=buddy.data.vetoSlots.len

    block:
      # Fetch and store account storage slots. On success, the `rc` value will
      # contain a list of left-over items to be re-processed.
      let rc = await buddy.fetchAndImportStorageSlots(req.q)
      if rc.isErr:
        # Save accounts/storage list to be processed later, then stop
        discard env.leftOver.append req
        let error = rc.error
        if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
          trace "Error fetching storage slots => stop", peer, error
          discard
        return

      # Reset error counts for detecting repeated timeouts
      buddy.data.errors.nTimeouts = 0

      for qLo in rc.value:
        # Handle queue left-overs for processing in the next cycle
        if qLo.q[0].firstSlot == Hash256() and 0 < env.leftOver.len:
          # Appending to last queue item is preferred over adding new item
          let item = env.leftOver.first.value
          item.q = item.q & qLo.q
        else:
          # Put back as-is.
          discard env.leftOver.append qLo
    # End while

  when extraTraceMessages:
    trace "Done fetching storage slots", peer, nAccounts=env.leftOver.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
