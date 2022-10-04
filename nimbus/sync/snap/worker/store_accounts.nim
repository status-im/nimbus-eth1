
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
##   unprocessed        | peer workers +          |
##   account ranges     | account database update | unprocessed storage slots
##   ========================================================================
##
##        +---------------------------------------+
##        |                                       |
##        v                                       |
##   <unprocessed> -----+------> <worker-0> ------+-----> OUTPUT
##                      |                         |
##                      +------> <worker-1> ------+
##                      |                         |
##                      +------> <worker-2> ------+
##                      :                         :
##

import
  chronicles,
  chronos,
  eth/[common/eth_types, p2p],
  stew/[interval_set, keyed_queue],
  stint,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_account_range],
  ./db/snap_db

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc withMaxLen(
    buddy: SnapBuddyRef;
    iv: LeafRange;
    maxlen: UInt256;
      ): LeafRange =
  ## Reduce accounts interval to maximal size
  if 0 < iv.len and iv.len <= maxLen:
    iv
  else:
    LeafRange.new(iv.minPt, iv.minPt + (maxLen - 1.u256))

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getUnprocessed(buddy: SnapBuddyRef): Result[LeafRange,void] =
  ## Fetch an interval from one of the account range lists.
  let
    env = buddy.data.pivotEnv
    accountRangeMax = high(UInt256) div buddy.ctx.buddiesMax.u256

  for ivSet in env.fetchAccounts:
    let rc = ivSet.ge()
    if rc.isOk:
      let iv = buddy.withMaxLen(rc.value, accountRangeMax)
      discard ivSet.reduce(iv)
      return ok(iv)

  err()

proc putUnprocessed(buddy: SnapBuddyRef; iv: LeafRange) =
  ## Shortcut
  discard buddy.data.pivotEnv.fetchAccounts[1].merge(iv)

proc delUnprocessed(buddy: SnapBuddyRef; iv: LeafRange) =
  ## Shortcut
  discard buddy.data.pivotEnv.fetchAccounts[1].reduce(iv)

proc markGloballyProcessed(buddy: SnapBuddyRef; iv: LeafRange) =
  ## Shortcut
  discard buddy.ctx.data.coveredAccounts.merge(iv)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc storeAccounts*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch accounts and store them in the database.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Get a range of accounts to fetch from
  let iv = block:
    let rc = buddy.getUnprocessed()
    if rc.isErr:
      trace "Currently no unprocessed accounts", peer, stateRoot
      return
    rc.value

  when extraTraceMessages:
    trace "Start fetching accounts", peer, stateRoot, iv

  # Process received accounts and stash storage slots to fetch later
  let dd = block:
    let rc = await buddy.getAccountRange(stateRoot, iv)
    if rc.isErr:
      buddy.putUnprocessed(iv) # fail => interval back to pool
      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        when extraTraceMessages:
          trace "Error fetching accounts => stop", peer, error
      return
    # Reset error counts for detecting repeated timeouts
    buddy.data.errors.nTimeouts = 0
    rc.value

  let
    nAccounts = dd.data.accounts.len
    nStorage = dd.withStorage.len

  block:
    let rc = ctx.data.snapDb.importAccounts(peer, stateRoot, iv.minPt, dd.data)
    if rc.isErr:
      # Bad data, just try another peer
      buddy.putUnprocessed(iv)
      buddy.ctrl.zombie = true
      when extraTraceMessages:
        let error = ComImportAccountsFailed
        trace "Accounts import failed => stop", peer, stateRoot,
          range=dd.consumed, nAccounts, nStorage, error
      return

  # Statistics
  env.nAccounts.inc(nAccounts)
  env.nStorage.inc(nStorage)

  # Register consumed intervals on the accumulator over all state roots
  buddy.markGloballyProcessed(dd.consumed)

  # Register consumed and bulk-imported (well, not yet) accounts range
  block registerConsumed:
    block:
      # Both intervals `min(iv)` and `min(dd.consumed)` are equal
      let rc = iv - dd.consumed
      if rc.isOk:
        # Now, `dd.consumed` < `iv`, return some unused range
        buddy.putUnprocessed(rc.value)
        break registerConsumed
    block:
      # The processed interval might be a bit larger
      let rc = dd.consumed - iv
      if rc.isOk:
        # Remove from unprocessed data. If it is not unprocessed, anymore
        # then it was doubly processed which is ok.
        buddy.delUnprocessed(rc.value)
        break registerConsumed
    # End registerConsumed

  # Store accounts on the storage TODO list.
  discard env.fetchStorage.append SnapSlotQueueItemRef(q: dd.withStorage)

  when extraTraceMessages:
    let withStorage = dd.withStorage.len
    trace "Done fetching accounts", peer, stateRoot, nAccounts, withStorage, iv

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
