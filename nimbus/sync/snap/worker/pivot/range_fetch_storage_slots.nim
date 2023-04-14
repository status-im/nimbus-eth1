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

{.push raises: [].}

import
  std/sets,
  chronicles,
  chronos,
  eth/p2p,
  stew/[interval_set, keyed_queue],
  "../../.."/[sync_desc, types],
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_storage_ranges],
  ../db/[hexary_error, snapdb_storage_slots],
  ./storage_queue_helper

logScope:
  topics = "snap-slot"

const
  extraTraceMessages = false # or true

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Storage slots fetch " & info

proc fetchCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  "{" &
    "piv=" & env.stateHeader.blockNumber.toStr & "," &
    "ctl=" & $buddy.ctrl.state & "," &
    "nQuFull=" & $env.fetchStorageFull.len & "," &
    "nQuPart=" & $env.fetchStoragePart.len & "," &
    "nParked=" & $env.parkedStorage.len & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchStorageSlotsImpl(
    buddy: SnapBuddyRef;
    req: seq[AccountSlotsHeader];
    env: SnapPivotRef;
      ): Future[Result[HashSet[NodeKey],void]]
      {.async.} =
  ## Fetch account storage slots and store them in the database, returns
  ## number of error or -1 for total failure.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot
    pivot = env.stateHeader.blockNumber.toStr # logging in `getStorageRanges()`

  # Get storages slots data from the network
  var stoRange = block:
    let rc = await buddy.getStorageRanges(stateRoot, req, pivot)
    if rc.isErr:
      if await buddy.ctrl.stopAfterSeriousComError(rc.error, buddy.only.errors):
        trace logTxt "fetch error", peer, ctx=buddy.fetchCtx(env),
          nReq=req.len, error=rc.error
      return err() # all of `req` failed
    rc.value

  # Reset error counts for detecting repeated timeouts, network errors, etc.
  buddy.only.errors.resetComError()

  var
    nSlotLists = stoRange.data.storages.len
    reject: HashSet[NodeKey]

  if 0 < nSlotLists:
    # Verify/process storages data and save it to disk
    let report = ctx.pool.snapDb.importStorageSlots(peer, stoRange.data)
    if 0 < report.len:
      if report[^1].slot.isNone:
        # Bad data, just try another peer
        buddy.ctrl.zombie = true
        # Failed to store on database, not much that can be done here
        error logTxt "import failed", peer, ctx=buddy.fetchCtx(env),
          nSlotLists=0, nReq=req.len, error=report[^1].error
        return err() # all of `req` failed

      # Push back error entries to be processed later
      for w in report:
        # All except the last item always index to a node argument. The last
        # item has been checked for, already.
        let
          inx = w.slot.get
          acc = stoRange.data.storages[inx].account
          splitOk = w.error in {RootNodeMismatch,RightBoundaryProofFailed}

        reject.incl acc.accKey

        if splitOk:
          # Some pathological cases need further investigation. For the
          # moment, provide partial split requeue. So a different range
          # will be unqueued and processed, next time.
          env.storageQueueAppendPartialSplit acc

        else:
          # Reset any partial result (which would be the last entry) to
          # requesting the full interval. So all the storage slots are
          # re-fetched completely for this account.
          env.storageQueueAppendFull acc

        error logTxt "import error", peer, ctx=buddy.fetchCtx(env), splitOk,
          nSlotLists, nRejected=reject.len, nReqInx=inx, nReq=req.len,
          nDangling=w.dangling.len, error=w.error

  # Return unprocessed left overs to batch queue. The `req[^1].subRange` is
  # the original range requested for the last item (if any.)
  let (_,removed) = env.storageQueueUpdate(stoRange.leftOver, reject)

  # Update statistics. The variable removed is set if the queue for a partial
  # slot range was logically removed. A partial slot range list has one entry.
  # So the correction factor for the slot lists statistics is `removed - 1`.
  env.nSlotLists.inc(nSlotLists - reject.len + (removed - 1))

  # Clean up, un-park successful slots (if any)
  for w in stoRange.data.storages:
    env.parkedStorage.excl w.account.accKey

  return ok(reject)

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
  trace logTxt "start", peer=buddy.peer, ctx=buddy.fetchCtx(env)

  # Fetch storage data and save it on disk. Storage requests are managed by
  # request queues for handling full/partial replies and re-fetch issues. For
  # all practical puroses, this request queue should mostly be empty.
  for (fetchFn, failMax) in [
        (storageQueueFetchFull, storageSlotsFetchFailedFullMax),
        (storageQueueFetchPartial, storageSlotsFetchFailedPartialMax)]:

    var
      ignored: HashSet[NodeKey]
      rc = Result[HashSet[NodeKey],void].ok(ignored) # set ok() start value

    # Run batch even if `archived` flag is set in order to shrink the queues.
    while buddy.ctrl.running and
          rc.isOk and
          ignored.len <= failMax:

      # Pull out the next request list from the queue
      let reqList = buddy.ctx.fetchFn(env, ignored)
      if reqList.len == 0:
        when extraTraceMessages:
          trace logTxt "queue exhausted", peer=buddy.peer,
            ctx=buddy.fetchCtx(env),
            isPartQueue=(fetchFn==storageQueueFetchPartial)
        break

      # Process list, store in database. The `reqList` is re-queued accordingly
      # in the `fetchStorageSlotsImpl()` function unless there is an error. In
      # the error case, the whole argument list `reqList` is left untouched.
      rc = await buddy.fetchStorageSlotsImpl(reqList, env)
      if rc.isOk:
        for w in rc.value:
          ignored.incl w                      # Ignoring bogus response items
      else:
        # Push back unprocessed jobs after error
        env.storageQueueAppendPartialSplit reqList

      when extraTraceMessages:
        trace logTxt "processed", peer=buddy.peer, ctx=buddy.fetchCtx(env),
          isPartQueue=(fetchFn==storageQueueFetchPartial),
          nReqList=reqList.len,
          nIgnored=ignored.len,
          subRange0=reqList[0].subRange.get(otherwise=FullNodeTagRange),
          account0=reqList[0].accKey,
          rc=(if rc.isOk: rc.value.len else: -1)
      # End `while`
    # End `for`

  trace logTxt "done", peer=buddy.peer, ctx=buddy.fetchCtx(env)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
