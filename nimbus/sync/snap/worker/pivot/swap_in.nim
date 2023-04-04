# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Swap in already allocated sub-tries
## ===================================
##
## This module imports sub-tries from other pivots into the current. It does
## so by detecting the top of an existing sub-trie in the current pivot and
## searches other pivots for the part of the sub-trie that is already
## available there. So it can be marked accomplished on the current pivot.
##
## Algorithm
## ---------
##
## * Find nodes with envelopes that have no account in common with any range
##   interval of the `processed` set of the current pivot.
##
## * From the nodes of the previous step, extract allocated nodes and try to
##   find them on previous pivots. Stop if there are no such nodes.
##
## * The portion of `processed` ranges on the other pivot that intersects with
##   the envelopes of the nodes have been downloaded already. And it is equally
##   applicable to the current pivot as it applies to the same sub-trie.
##
##   So the intersection of `processed` with the node envelope will be copied
##   to to the `processed` ranges of the current pivot.
##
## * Rinse and repeat.
##
import
  std/[math, sequtils],
  chronicles,
  eth/[common, p2p],
  stew/[byteutils, interval_set, keyed_queue, sorted_set],
  ../../../../utils/prettify,
  ../../../types,
  "../.."/[range_desc, worker_desc],
  ../db/[hexary_desc, hexary_envelope, hexary_error,
         hexary_paths, snapdb_accounts]

{.push raises: [].}

logScope:
  topics = "snap-swapin"

type
  SwapInPivot = object
    ## Subset of `SnapPivotRef` with relevant parts, only
    rootKey: NodeKey             ## Storage slots & accounts
    processed: NodeTagRangeSet   ## Storage slots & accounts
    pivot: SnapPivotRef          ## Accounts only

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Swap-in " & info

proc `$`(node: NodeSpecs): string =
  node.partialPath.toHex

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullPC3

proc `$`(iv: NodeTagRange): string =
  iv.fullPC3

proc toPC(w: openArray[NodeSpecs]; n: static[int] = 3): string =
  let sumUp = w.mapIt(it.hexaryEnvelope.len).foldl(a+b, 0.u256)
  (sumUp.to(float) / (2.0^256)).toPC(n)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc existsInTrie(
  node: NodeSpecs;                   # Probe node to test to exist
  rootKey: NodeKey;                  # Start node into hexary trie
  getFn: HexaryGetFn;                # Abstract database access
    ): bool =
  ## Check whether this node exists on the sub-trie starting at ` rootKey`
  var error: HexaryError

  try:
    let rc = node.partialPath.hexaryPathNodeKey(rootKey, getFn)
    if rc.isOk:
      return rc.value == node.nodeKey
  except RlpError:
    error = RlpEncoding
  except CatchableError:
    error = ExceptionError

  when extraTraceMessages:
    if error != NothingSerious:
      trace logTxt "other trie check node failed", node, error

  false


template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc uncoveredEnvelopes(
    processed: NodeTagRangeSet;        # To be complemented
    rootKey: NodeKey;                  # Start node into hexary trie
    getFn: HexaryGetFn;                # Abstract database access
      ): seq[NodeSpecs] =
  ## Compile the complement of the union of the `processed` intervals and
  ## express this complement as a list of envelopes of sub-tries.
  ##
  var decomposed = "n/a"
  noExceptionOops("swapIn"):
    let rc = processed.hexaryEnvelopeDecompose(rootKey, getFn)
    if rc.isOk:
      # Return allocated nodes only
      result = rc.value.filterIt(0 < it.nodeKey.ByteArray32.getFn().len)

      when extraTraceMessages:
        decomposed = rc.value.toPC

  when extraTraceMessages:
    trace logTxt "unprocessed envelopes", processed,
      nProcessed=processed.chunks, decomposed,
      nResult=result.len, result=result.toPC


proc otherProcessedRanges(
    node: NodeSpecs;                 # Top node of portential sub-trie
    otherPivots: seq[SwapInPivot];   # Other pivots list
    rootKey: NodeKey;                # Start node into hexary trie
    getFn: HexaryGetFn;              # Abstract database access
      ): seq[NodeTagRangeSet] =
  ## Collect already processed ranges from other pivots intersecting with the
  ## envelope of the argument `node`.  The list of other pivots is represented
  ## by the argument iterator `otherPivots`.
  let envelope = node.hexaryEnvelope

  noExceptionOops("otherProcessedRanges"):
    # For the current `node` select all hexary sub-tries that contain the same
    # node `node.nodeKey` for the partial path `node.partianPath`.
    for n,op in otherPivots:
      result.add NodeTagRangeSet.init()

      # Check whether the node is shared
      if node.existsInTrie(op.rootKey, getFn):
        # Import already processed part of the envelope of `node` into the
        # `batch.processed` set of ranges.
        let
          other = op.processed
          touched = other.hexaryEnvelopeTouchedBy node

        for iv in touched.increasing:
          let segment = (envelope * iv).value
          discard result[^1].merge segment

          #when extraTraceMessages:
          #  trace logTxt "collect other pivot segment", n, node, segment

        #when extraTraceMessages:
        #  if 0 < touched.chunks:
        #    trace logTxt "collected other pivot", n, node,
        #      other, nOtherChunks=other.chunks,
        #      touched, nTouched=touched.chunks,
        #      collected=result[^1]

# ------------------------------------------------------------------------------
# Private functions, swap-in functionality
# ------------------------------------------------------------------------------

proc swapIn(
    processed: NodeTagRangeSet;      # Covered node ranges to be updated
    unprocessed: var SnapTodoRanges; # Uncovered node ranges to be updated
    otherPivots: seq[SwapInPivot];   # Other pivots list (read only)
    rootKey: NodeKey;                # Start node into target hexary trie
    getFn: HexaryGetFn;              # Abstract database access
    loopMax: int;                    # Prevent from looping too often
      ): (seq[NodeTagRangeSet],int) =
  ## Collect processed already ranges from argument `otherPivots` and merge them
  ## it onto the argument sets `processed` and `unprocessed`. For each entry
  ## of `otherPivots`, this function returns a list of merged (aka swapped in)
  ## ranges. It also returns the number of main loop runs with non-empty merges.
  var
    swappedIn = newSeq[NodeTagRangeSet](otherPivots.len)
    lapCount = 0                               # Loop control
    allMerged = 0.u256                         # Logging & debugging

  # Initialise return value
  for n in 0 ..< swappedIn.len:
    swappedIn[n] = NodeTagRangeSet.init()

  noExceptionOops("swapIn"):
    # Swap in node ranges from other pivots
    while lapCount < loopMax:
      var merged = 0.u256                      # Loop control

      let checkNodes = processed.uncoveredEnvelopes(rootKey, getFn)
      for node in checkNodes:

        # Process table of sets from other pivots with ranges intersecting
        # with the `node` envelope.
        for n,rngSet in node.otherProcessedRanges(otherPivots, rootKey, getFn):

          # Merge `rngSet` into `swappedIn[n]` and `pivot.processed`,
          # and remove `rngSet` from ` pivot.unprocessed`
          for iv in rngSet.increasing:
            discard swappedIn[n].merge iv      # Imported range / other pivot
            merged += processed.merge iv       # Import range as processed
            unprocessed.reduce iv              # No need to re-fetch

      if merged == 0:                          # Loop control
        break

      lapCount.inc
      allMerged += merged                      # Statistics, logging

      when extraTraceMessages:
        trace logTxt "inherited ranges", lapCount, nCheckNodes=checkNodes.len,
          merged=((merged.to(float) / (2.0^256)).toPC(3)),
          allMerged=((allMerged.to(float) / (2.0^256)).toPC(3))

      # End while()

  (swappedIn,lapCount)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc swapInAccounts*(
    ctx: SnapCtxRef;                   # Global context
    env: SnapPivotRef;                 # Current pivot environment
    loopMax = 100;                     # Prevent from looping too often
      ): int =
  ## Variant of `swapIn()` for the particular case of accounts database pivots.
  let fa = env.fetchAccounts
  if fa.processed.isFull:
    return # nothing to do

  let
    pivot {.used.} = "#" & $env.stateHeader.blockNumber # Logging & debugging
    rootKey = env.stateHeader.stateRoot.to(NodeKey)
    getFn = ctx.pool.snapDb.getAccountFn

    others = toSeq(ctx.pool.pivotTable.nextPairs)

                # Swap in from mothballed pivots different from the current one
                .filterIt(it.data.archived and it.key.to(NodeKey) != rootKey)

                # Extract relevant parts
                .mapIt(SwapInPivot(
                  rootKey:   it.key.to(NodeKey),
                  processed: it.data.fetchAccounts.processed,
                  pivot:     it.data))

  if others.len == 0:
    return # nothing to do

  when extraTraceMessages:
    trace logTxt "accounts start", pivot, nOthers=others.len

  var
   nLaps = 0                                     # Logging & debugging
   nSlotAccounts = 0                             # Logging & debugging
   swappedIn: seq[NodeTagRangeSet]

  noExceptionOops("swapInAccounts"):
    (swappedIn, nLaps) = swapIn(
      fa.processed, fa.unprocessed, others, rootKey, getFn, loopMax)

    if 0 < nLaps:
      # Update storage slots
      for n in 0 ..< others.len:

        #when extraTraceMessages:
        #  if n < swappedIn[n].chunks:
        #    trace logTxt "post-processing storage slots", n, nMax=others.len,
        #      changes=swappedIn[n], chunks=swappedIn[n].chunks

        # Revisit all imported account key ranges
        for iv in swappedIn[n].increasing:

          # The `storageAccounts` list contains indices for storage slots,
          # mapping account keys => storage root
          var rc = others[n].pivot.storageAccounts.ge(iv.minPt)
          while rc.isOk and rc.value.key <= iv.maxPt:

            # Fetch storage slots specs from `fetchStorageFull` list
            let stRoot = rc.value.data
            if others[n].pivot.fetchStorageFull.hasKey(stRoot):
              let accKey = others[n].pivot.fetchStorageFull[stRoot].accKey
              discard env.fetchStorageFull.append(
                stRoot, SnapSlotsQueueItemRef(acckey: accKey))
              nSlotAccounts.inc

            rc = others[n].pivot.storageAccounts.gt(rc.value.key)

  when extraTraceMessages:
    trace logTxt "accounts done", pivot, nOthers=others.len, nLaps,
      nSlotAccounts

  nLaps

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
