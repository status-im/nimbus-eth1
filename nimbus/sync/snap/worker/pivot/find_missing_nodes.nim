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
import
  std/sequtils,
  eth/common,
  stew/interval_set,
  "../../.."/[sync_desc, types],
  "../.."/[constants, range_desc, worker_desc],
  ../db/[hexary_desc, hexary_envelope, hexary_inspect]

{.push raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc findMissingNodes*(
    ranges: SnapRangeBatchRef;
    rootKey: NodeKey;
    getFn: HexaryGetFn;
    planBLevelMax: uint8;
      ): (seq[NodeSpecs],uint8,uint64) =
  ## Find some missing nodes in the hexary trie database.
  var nodes: seq[NodeSpecs]

  # Plan A, try complement of `processed`
  noExceptionOops("compileMissingNodesList"):
    if not ranges.processed.isEmpty:
      # Get unallocated nodes to be fetched
      let rc = ranges.processed.hexaryEnvelopeDecompose(rootKey, getFn)
      if rc.isOk:
        nodes = rc.value

        # The gaps between resuling envelopes are either ranges that have
        # no leaf nodes, or they are contained in the `processed` range. So
        # these gaps are be merged back into the `processed` set of ranges.
        let gaps = NodeTagRangeSet.init()
        discard gaps.merge(low(NodeTag),high(NodeTag))       # All range
        for w in nodes: discard gaps.reduce w.hexaryEnvelope # Remove envelopes

        # Merge gaps into `processed` range and update `unprocessed` ranges
        for iv in gaps.increasing:
          discard ranges.processed.merge iv
          ranges.unprocessed.reduce iv

        # Check whether the hexary trie is complete
        if ranges.processed.isFull:
          return

        # Remove allocated nodes
        let missing = nodes.filterIt(it.nodeKey.ByteArray32.getFn().len == 0)
        if 0 < missing.len:
          return (missing, 0u8, 0u64)

  # Plan B, carefully employ `hexaryInspect()`
  if 0 < nodes.len:
    try:
      let
        paths = nodes.mapIt it.partialPath
        stats = getFn.hexaryInspectTrie(rootKey, paths,
          stopAtLevel = planBLevelMax,
          maxDangling = fetchRequestTrieNodesMax)
      result = (stats.dangling, stats.level, stats.count)
    except:
      discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
