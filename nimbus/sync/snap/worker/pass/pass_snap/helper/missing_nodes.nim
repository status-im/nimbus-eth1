# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Find missing nodes for healing
## ==============================
##
## This module searches for missing nodes in the database (which means that
## nodes which link to missing ones must exist.)
##
## Algorithm
## ---------
##
## * Find dangling node links in the current account trie by trying *plan A*,
##   and continuing with *plan B* only if *plan A* fails.
##
##   A. Try to find nodes with envelopes that have no account in common with
##   any range interval of the `processed` set of the hexary trie. This
##   action will
##
##   + either determine that there are no such envelopes implying that the
##     accounts trie is complete (then stop here)
##
##   + or result in envelopes related to nodes that are all allocated on the
##     accounts trie (fail, use *plan B* below)
##
##   + or result in some envelopes related to dangling nodes.
##
##   B. Employ the `hexaryInspect()` trie perusal function in a limited mode
##   for finding dangling (i.e. missing) sub-nodes below the allocated nodes.
##
##   C. Remove empry intervals from the accounting ranges. This is a pure
##   maintenance process that applies if A and B fail.
##
## Discussion
## ----------
##
## For *plan A*, the complement of ranges in the `processed` is determined
## and expressed as a list of node envelopes. As a consequence, the gaps
## beween the envelopes are either blind ranges that have no leaf nodes in
## the databse, or they are contained in the `processed` range. These gaps
## will be silently merged into the `processed` set of ranges.
##
## For *plan B*, a worst case scenario of a failing *plan B* must be solved
## by fetching and storing more nodes with other means before using this
## algorithm to find more missing nodes.
##
## Due to the potentially poor performance using `hexaryInspect()`.there is
## no general solution for *plan B* by recursively searching the whole hexary
## trie database for more dangling nodes.
##
{.push raises: [].}

import
  std/sequtils,
  chronicles,
  chronos,
  eth/common,
  stew/interval_set,
  "../../../.."/[constants, range_desc],
  ../../../db/[hexary_desc, hexary_envelope, hexary_error, hexary_inspect,
               hexary_nearby],
  ../snap_pass_desc

logScope:
  topics = "snap-find"

type
  MissingNodesSpecs* = object
    ## Return type for `findMissingNodes()`
    missing*: seq[NodeSpecs]
    level*: uint8
    visited*: uint64
    emptyGaps*: NodeTagRangeSet

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Find missing nodes " & info

template ignExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    trace logTxt "Ooops", `info`=info, name=($e.name), msg=(e.msg)

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc missingNodesFind*(
    ranges: RangeBatchRef;
    rootKey: NodeKey;
    getFn: HexaryGetFn;
    planBLevelMax: uint8;
    planBRetryMax: int;
    planBRetrySleepMs: int;
    forcePlanBOk = false;
      ): Future[MissingNodesSpecs]
      {.async.} =
  ## Find some missing nodes in the hexary trie database.
  var nodes: seq[NodeSpecs]

  # Plan A, try complement of `processed`
  noExceptionOops("compileMissingNodesList"):
    if not ranges.processed.isEmpty:
      # Get unallocated nodes to be fetched
      let rc = ranges.processed.hexaryEnvelopeDecompose(rootKey, getFn)
      if rc.isOk:
        # Extract nodes from the list that do not exisit in the database
        # and need to be fetched (and allocated.)
        let missing = rc.value.filterIt(it.nodeKey.ByteArray32.getFn().len == 0)
        if 0 < missing.len:
          when extraTraceMessages:
            trace logTxt "plan A", nNodes=nodes.len, nMissing=missing.len
          return MissingNodesSpecs(missing: missing)

  when extraTraceMessages:
    trace logTxt "plan A not applicable", nNodes=nodes.len

  # Plan B, carefully employ `hexaryInspect()`
  var nRetryCount = 0
  if 0 < nodes.len or forcePlanBOk:
    ignExceptionOops("compileMissingNodesList"):
      let
        paths = nodes.mapIt it.partialPath
        suspend = if planBRetrySleepMs <= 0: 1.nanoseconds
                  else: planBRetrySleepMs.milliseconds
      var
        maxLevel = planBLevelMax
        stats = getFn.hexaryInspectTrie(rootKey, paths,
          stopAtLevel = maxLevel,
          maxDangling = fetchRequestTrieNodesMax)

      while stats.dangling.len == 0 and
            nRetryCount < planBRetryMax and
            1 < maxLevel and
            not stats.resumeCtx.isNil:
        await sleepAsync suspend
        nRetryCount.inc
        maxLevel.dec
        when extraTraceMessages:
          trace logTxt "plan B retry", forcePlanBOk, nRetryCount, maxLevel
        stats = getFn.hexaryInspectTrie(rootKey,
          resumeCtx = stats.resumeCtx,
          stopAtLevel = maxLevel,
          maxDangling = fetchRequestTrieNodesMax)

      result = MissingNodesSpecs(
        missing: stats.dangling,
        level:   stats.level,
        visited: stats.count)

      if 0 < result.missing.len:
        when extraTraceMessages:
          trace logTxt "plan B", forcePlanBOk, nNodes=nodes.len,
            nDangling=result.missing.len, level=result.level,
            nVisited=result.visited, nRetryCount
        return

  when extraTraceMessages:
    trace logTxt "plan B not applicable", forcePlanBOk, nNodes=nodes.len,
      level=result.level, nVisited=result.visited, nRetryCount

  # Plan C, clean up intervals

  # Calculate `gaps` as the complement of the `processed` set of intervals
  let gaps = NodeTagRangeSet.init()
  discard gaps.merge FullNodeTagRange
  for w in ranges.processed.increasing: discard gaps.reduce w

  # Clean up empty gaps in the processed range
  result.emptyGaps = NodeTagRangeSet.init()
  for gap in gaps.increasing:
    let rc = gap.minPt.hexaryNearbyRight(rootKey,getFn)
    if rc.isOk:
      # So there is a right end in the database and there is no leaf in
      # the right open interval interval [gap.minPt,rc.value).
      discard result.emptyGaps.merge(gap.minPt, rc.value)
    elif rc.error == NearbyBeyondRange:
      discard result.emptyGaps.merge(gap.minPt, high(NodeTag))

  when extraTraceMessages:
    trace logTxt "plan C", nGapFixes=result.emptyGaps.chunks,
      nGapOpen=(ranges.processed.chunks - result.emptyGaps.chunks)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
