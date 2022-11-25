# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  chronicles,
  chronos,
  eth/[common, p2p],
  stew/interval_set,
  ".."/[constants, range_desc, worker_desc],
  ./db/[hexary_desc, hexary_error, hexary_inspect, hexary_paths]

{.push raises: [Defect].}

logScope:
  topics = "snap-subtrie"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Sub-trie helper " & info

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc doInspect(
    getFn: HexaryGetFn;                ## Abstract database access
    rootKey: NodeKey;                  ## Start of hexary trie
    partialPaths: seq[Blob];           ## Nodes with prob. dangling child links
    resumeCtx: TrieNodeStatCtxRef;     ## Resume previous inspection
     ): Result[TrieNodeStat,HexaryDbError]
     {.gcsafe, raises: [Defect,RlpError].} =
  ## ..
  let stats = getFn.hexaryInspectTrie(
    rootKey, partialPaths, resumeCtx, healInspectionBatch)

  if stats.stopped:
    return err(TrieLoopAlert)

  ok(stats)


proc getOverlapping(
    batch: SnapRangeBatchRef;          ## Healing data support
    iv: NodeTagRange;                  ## Reference interval
      ): Result[NodeTagRange,void] =
  ## Find overlapping interval in `batch`
  block:
    let rc = batch.processed.ge iv.minPt
    if rc.isOk and rc.value.minPt <= iv.maxPt:
      return ok(rc.value)
  block:
    let rc = batch.processed.le iv.maxPt
    if rc.isOk and iv.minPt <= rc.value.maxPt:
      return ok(rc.value)
  err()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc subTriesFromPartialPaths*(
    getFn: HexaryGetFn;                ## Abstract database access
    stateRoot: Hash256;                ## Start of hexary trie
    batch: SnapRangeBatchRef;          ## Healing data support
    sickSubTriesMaxLen = high(int);    ## Max length of `sickSubTries`
      ): Future[Result[void,HexaryDbError]]
      {.async.} =
  ## Starting with a given set of potentially dangling account nodes
  ## `checkNodes`, this set is filtered and processed. The outcome is
  ## fed back to the vey same list `checkNodes`

  # Process might be expensive, so only a single instance is allowed to run it
  if batch.lockTriePerusal:
    return err(TrieIsLockedForPerusal)
  batch.lockTriePerusal = true

  let
    rootKey = stateRoot.to(NodeKey)
  var
    error: HexaryDbError
    count = 0                                      # for logging
    start = Moment.now()                           # for logging

  block errorWhenOutside:
    try:
      while batch.sickSubTries.len < sickSubTriesMaxLen:
        # Inspect hexary trie for dangling nodes
        let rc = getFn.doInspect(rootKey, batch.checkNodes, batch.resumeCtx)
        if rc.isErr:
          error = rc.error
          break errorWhenOutside

        count.inc

        # Update context for async threading environment
        batch.resumeCtx = rc.value.resumeCtx
        batch.checkNodes.setLen(0)

        # Collect result
        batch.sickSubTries = batch.sickSubTries & rc.value.dangling

        # Done unless there is some resumption context
        if rc.value.resumeCtx.isNil:
          break

        when extraTraceMessages:
          trace logTxt "inspection wait", count,
            elapsed=(Moment.now()-start),
            sleep=healInspectionBatchWaitNanoSecs,
            sickSubTriesLen=batch.sickSubTries.len, sickSubTriesMaxLen,
            resumeCtxLen = batch.resumeCtx.hddCtx.len

        # Allow async task switch and continue. Note that some other task might
        # steal some of the `sickSubTries` var argument.
        await sleepAsync healInspectionBatchWaitNanoSecs.nanoseconds

      batch.lockTriePerusal = false
      return ok()

    except RlpError:
      error = RlpEncoding

  batch.sickSubTries = batch.sickSubTries & batch.resumeCtx.to(seq[NodeSpecs])
  batch.resumeCtx = nil

  batch.lockTriePerusal = false
  return err(error)


proc subTriesNodesReclassify*(
    getFn: HexaryGetFn;                ## Abstract database access
    rootKey: NodeKey;                  ## Start node into hexary trie
    batch: SnapRangeBatchRef;          ## Healing data support
      ) {.gcsafe, raises: [Defect,KeyError].} =
  ## Check whether previously missing nodes from the `sickSubTries` list have
  ## been magically added to the database since it was checked last time. These
  ## nodes will me moved to `checkNodes` for further processing. Also, some
  ## full sub-tries might have been added which can be checked against
  ## the `processed` range set.

  # Move `sickSubTries` entries that have now an exisiting node to the
  # list of partial paths to be re-checked.
  block:
    var delayed: seq[NodeSpecs]
    for w in batch.sickSubTries:
      if 0 < getFn(w.nodeKey.ByteArray32).len:
        batch.checkNodes.add w.partialPath
      else:
        delayed.add w
    batch.sickSubTries = delayed

  # Remove `checkNodes` entries with complete known sub-tries.
  var
    doneWith: seq[Blob]        # loop will not recurse on that list
    count = 0                  # for logging only

  # `While` loop will terminate with processed paths in `doneWith`.
  block:
    var delayed: seq[Blob]
    while 0 < batch.checkNodes.len:

      when extraTraceMessages:
        trace logTxt "reclassify", count,
          nCheckNodes=batch.checkNodes.len

      for w in batch.checkNodes:
        let
          iv = w.pathEnvelope
          nCov = batch.processed.covered iv

        if iv.len <= nCov:
          # Fully processed envelope, no need to keep `w` any longer
          when extraTraceMessages:
            trace logTxt "reclassify discard", count, partialPath=w,
              nDelayed=delayed.len
          continue

        if 0 < nCov:
          # Partially processed range, fetch an overlapping interval and
          # remove that from the envelope of `w`.
          try:
            let paths = w.dismantle(
              rootKey, batch.getOverlapping(iv).value, getFn)
            delayed &= paths
            when extraTraceMessages:
              trace logTxt "reclassify dismantled", count, partialPath=w,
                nPaths=paths.len, nDelayed=delayed.len
            continue
          except RlpError:
            discard

        # Not processed at all. So keep `w` but there is no need to look
        # at it again in the next lap.
        doneWith.add w

      # Prepare for next lap
      batch.checkNodes.swap delayed
      delayed.setLen(0)

  batch.checkNodes = doneWith.pathSortUniq

  when extraTraceMessages:
    trace logTxt "reclassify finalise", count,
      nDoneWith=doneWith.len, nCheckNodes=batch.checkNodes.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

