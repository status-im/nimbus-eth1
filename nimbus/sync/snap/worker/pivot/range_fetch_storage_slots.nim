# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Fetch storage slots DB ranges
## =============================
##
## In principle, this algorithm is a generalised version of the one for
## installing on the accounts hexary trie database. The difference is that
## there are many such storage slots hexary trie database which are typically
## quite small. So the normal action is to download and install a full hexary
## trie rather than merging a partial one.
##
## Algorithm
## ---------
##
## * Handle full storage slot hexary trie entries
##
##   + Remove a list of full storage slot hexary trie entries from the queue of
##     full requests `env.fetchStorageFull`.
##
##     The *full* adjective indicates that a complete trie will be installed
##     rather an a partial one merged. Stop if there are no more full entries
##     and proceed with handling partial entries.
##
##   + Fetch and install the full trie entries of that list from the network.
##
##   + For a list entry that was partially received (there is only one per
##     reply message), store the remaining parts to install on the queue of
##     partial storage slot hexary trie entries `env.fetchStoragePart`.
##
##   + Rinse and repeat
##
## * Handle partial storage slot hexary trie entries
##
##   + Remove a single partial storage slot hexary trie entry from the queue
##     of partial requests `env.fetchStoragePart`.
##
##     The detailed handling of this entry resembles the algorithm described
##     for fetching accounts regarding sets of ranges `processed` and
##     `unprocessed`. Stop if there are no more entries.
##
##   + Fetch and install the partial trie entry from the network.
##
##   + Rinse and repeat
##
## Discussion
## ----------
##
## If there is a hexary trie integrity problem when storing a response to a
## full or partial entry request, re-queue the entry on the queue of partial
## requests `env.fetchStoragePart` with the next partial range to fetch half
## of the current request.
##
## In general, if  an error occurs, the entry that caused the error is moved
## or re-stored onto the queue of partial requests `env.fetchStoragePart`.
##
import
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/[interval_set, keyed_queue],
  stint,
  ../../../sync_desc,
  "../.."/[range_desc, worker_desc],
  ../com/[com_error, get_storage_ranges],
  ../db/[hexary_error, snapdb_storage_slots],
  ./storage_queue_helper

{.push raises: [Defect].}

logScope:
  topics = "snap-range"

const
  extraTraceMessages = false or true

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Storage slots range " & info

proc fetchCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  let
    ctx = buddy.ctx
    nStoQu = (env.fetchStorageFull.len +
              env.fetchStoragePart.len +
              env.parkedStorage.len)
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "runState=" & $buddy.ctrl.state & "," &
    "nStoQu=" & $nStoQu & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc storeStoragesSingleBatch(
    buddy: SnapBuddyRef;
    req: seq[AccountSlotsHeader];
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch account storage slots and store them in the database.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  # Get storages slots data from the network
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, req, pivot)
    if rc.isErr:
      env.storageQueueAppend req

      let error = rc.error
      if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
        trace logTxt "fetch error => stop", peer, ctx=buddy.fetchCtx(env),
          nReq=req.len, error
      return
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.data.errors.resetComError()

  var gotSlotLists = stoRange.data.storages.len
  if 0 < gotSlotLists:

    # Verify/process storages data and save it to disk
    let report = ctx.data.snapDb.importStorageSlots(
      peer, stoRange.data, noBaseBoundCheck = true)

    if 0 < report.len:
      let topStoRange = stoRange.data.storages.len - 1

      if report[^1].slot.isNone:
        # Failed to store on database, not much that can be done here
        env.storageQueueAppend req
        gotSlotLists.dec(report.len - 1) # for logging only

        error logTxt "import failed", peer, ctx=buddy.fetchCtx(env),
          nSlotLists=gotSlotLists, nReq=req.len, error=report[^1].error
        return

      # Push back error entries to be processed later
      for w in report:
        # All except the last item always index to a node argument. The last
        # item has been checked for, already.
        let
          inx = w.slot.get
          acc = stoRange.data.storages[inx].account

        if w.error == RootNodeMismatch:
          # Some pathological case, needs further investigation. For the
          # moment, provide partial fetches.
          env.storageQueueAppendPartialBisect acc

        elif w.error == RightBoundaryProofFailed and
             acc.subRange.isSome and 1 < acc.subRange.unsafeGet.len:
          # Some pathological case, needs further investigation. For the
          # moment, provide a partial fetches.
          env.storageQueueAppendPartialBisect acc

        else:
          # Reset any partial result (which would be the last entry) to
          # requesting the full interval. So all the storage slots are
          # re-fetched completely for this account.
          env.storageQueueAppendFull acc

          # Last entry might be partial (if any)
          #
          # Forget about partial result processing if the last partial entry
          # was reported because
          # * either there was an error processing it
          # * or there were some gaps reprored as dangling links
          stoRange.data.proof = @[]

        # Update local statistics counter for `nSlotLists` counter update
        gotSlotLists.dec

        error logTxt "processing error", peer, ctx=buddy.fetchCtx(env),
          nSlotLists=gotSlotLists, nReqInx=inx, nReq=req.len,
          nDangling=w.dangling.len, error=w.error

    # Update statistics
    if gotSlotLists == 1 and
       req[0].subRange.isSome and
       env.fetchStoragePart.hasKey req[0].storageRoot:
      # Successful partial request, but not completely done with yet.
      gotSlotLists = 0

    env.nSlotLists.inc(gotSlotLists)

  # Return unprocessed left overs to batch queue
  env.storageQueueAppend(stoRange.leftOver, req[^1].subRange)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc rangeFetchStorageSlots*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetch some account storage slots and store them in the database. If left
  ## anlone (e.t. no patallel activated processes) this function tries to fetch
  ## each work item on the queue at least once.For partial partial slot range
  ## items this means in case of success that the outstanding range has become
  ## at least smaller.

  # Fetch storage data and save it on disk. Storage requests are managed by
  # request queues for handling full/partial replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.
  if 0 < env.fetchStorageFull.len or 0 < env.fetchStoragePart.len:
    let
      ctx = buddy.ctx
      peer = buddy.peer

    when extraTraceMessages:
      trace logTxt "start", peer, ctx=buddy.fetchCtx(env)


    # Run batch even if `archived` flag is set in order to shrink the queues.
    while buddy.ctrl.running:
      # Pull out the next request list from the queue
      let (req, nComplete, nPartial) = ctx.storageQueueFetchFull(env)
      if req.len == 0:
        break

      when extraTraceMessages:
        trace logTxt "fetch full", peer, ctx=buddy.fetchCtx(env),
          nStorageQuFull=env.fetchStorageFull.len, nReq=req.len,
          nPartial, nComplete

      await buddy.storeStoragesSingleBatch(req, env)
      for w in req:
        env.parkedStorage.excl w.accKey                # Done with these items

    # Ditto for partial queue
    while buddy.ctrl.running:
      # Pull out the next request item from the queue
      let rc = env.storageQueueFetchPartial()
      if rc.isErr:
        break

      when extraTraceMessages:
        let
          subRange = rc.value.subRange.get
          account = rc.value.accKey
        trace logTxt "fetch partial", peer, ctx=buddy.fetchCtx(env),
          nStorageQuPart=env.fetchStoragePart.len, subRange, account

      await buddy.storeStoragesSingleBatch(@[rc.value], env)
      env.parkedStorage.excl rc.value.accKey           # Done with this item


    when extraTraceMessages:
      trace logTxt "done", peer, ctx=buddy.fetchCtx(env)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
