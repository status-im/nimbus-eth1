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
## Note that the terminology hinges on *account pivots* but is implemented in
## a more general way where
##
## * the current pivot is of type `SnapRangeBatchRef`
##
## * other pivots are represented by an iterator of type `SwapInPivots`
##
## So the algorithm can be transferred to other that accounting pivot
## situations.
##
## Algorithm
## ---------
##
## * On the *current pivot*, use the `processed` ranges of accounts to find all
##   the nodes the envelopes of which are disjunct to the `processed` ranges
##   (see module `hexary_envelope` for supporting functions.)
##
## * Select all the non-dangling/existing nodes disjunct envelopes from the
##   previous step.
##
## * For all the selected non-dangling nodes from the previous step, check
##   which ones are present in other pivots. This means that for a given
##   existing node in the current pivot its *partial path* can be applied
##   to the *state root* key of another pivot ending up at the same node key.
##
##   The portion of `processed` ranges on the other pivot that intersects with
##   the envelope of the node has been downloaded already. It is equally
##   applicable to the current pivot as it applies to the same sub-trie. So
##   the intersection of `processed` with the node envelope can be copied to
##   to the `processed` ranges of the current pivot.
##
## * Rinse and repeat.
##
import
  std/[sequtils, strutils],
  chronicles,
  eth/[common, p2p],
  stew/[byteutils, interval_set, keyed_queue, sorted_set],
  ../../../utils/prettify,
  ".."/[range_desc, worker_desc],
  ./db/[hexary_desc, hexary_error, hexary_envelope,
        hexary_paths, snapdb_accounts]

{.push raises: [Defect].}

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

when extraTraceMessages:
  import std/math, ../../types

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Swap-in helper " & info

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc decompose(
    node: NodeSpecs;                   # Contains hex encoded partial path
    iv: NodeTagRange;                  # Proofed range of leaf paths
    rootKey: NodeKey;                  # Start node into hexary trie
    getFn: HexaryGetFn;                # Abstract database access
      ): Result[seq[NodeSpecs],void] =
  ## Decompose, succeed only if there is a change
  var error: HexaryError

  try:
    let rc = node.partialPath.hexaryEnvelopeDecompose(rootKey, iv, getFn)
    if rc.isErr:
      error = rc.error
    elif rc.value.len != 1 or rc.value[0].nodeKey != node.nodeKey:
      return ok(rc.value)
    else:
      return err()
  except RlpError:
    error = RlpEncoding

  when extraTraceMessages:
    trace logTxt "envelope decomposition failed",
      node=node.partialPath.toHex, error

  err()


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

  when extraTraceMessages:
    trace logTxt "check nodes failed",
      partialPath=node.partialPath.toHex, error

  false


template noKeyErrorOops(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Not possible (" & info & "): " & e.msg

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except Defect as e:
    raise e
  except Exception as e:
    raiseAssert "Ooops " & info & ": name=" & $e.name & " msg=" & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc decomposeCheckNodes(
    pivot: SnapRangeBatchRef;          # Healing data support
    rootKey: NodeKey;                  # Start node into hexary trie
    getFn: HexaryGetFn;                # Abstract database access
      ): Result[seq[NodeSpecs],void] =
  ## Decompose the `checkNodes` list of the argument `pivot` relative to the
  ## set `processed` of processed leaf node ranges.
  ##
  ## The function fails if there wan no change to the `checkNodes` list.
  var
    delayed: seq[NodeSpecs]
    didSomething = 0

  # Remove `checkNodes` entries with known complete sub-tries.
  for node in pivot.checkNodes:
    var paths: seq[NodeSpecs]

    # For a Partially processed range, fetch overlapping intervals and
    # sort of remove them from the envelope of `w`.
    for touched in pivot.processed.hexaryEnvelopeTouchedBy(node).increasing:
      let rc = node.decompose(touched, rootKey, getFn)
      if rc.isOk:
        paths &= rc.value
        didSomething.inc
        when extraTraceMessages:
          trace logTxt "checkNodes decompose", nDelayed=delayed.len,
            node=node.partialPath.toHex, nPaths=paths.len,
            newPaths=rc.value.mapIt(it.partialPath.toHex).join(",")
      # End inner for()

    delayed &= paths
    # End outer for()

  if 0 < didSomething:
    noKeyErrorOops("subTriesCheckNodesDecompose"):
      # Remove duplicates in resulting path list
      return ok(delayed.hexaryEnvelopeUniq)

  err()


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
  var count = 0          # logging & debugging

  noExceptionOops("otherProcessedRanges"):
    # For the current `node` select all hexary sub-tries that contain the same
    # node `node.nodeKey` for the partial path `node.partianPath`.
    for rp in otherPivots.items:
      # Check whether the node is shared
      let haveNode = node.existsInTrie(rp.rootKey, getFn)

      var subCount = 0   # logging & debugging
      count.inc          # logging & debugging

      result.add NodeTagRangeSet.init()

      if not haveNode:
        trace logTxt "history loop", count, node=node.partialPath.toHex,
          processed=rp.processed.fullFactor.toPC(3), haveNode

      if haveNode:
        when extraTraceMessages:
          trace logTxt "history loop => sub start", count,
            nTouched=rp.processed.hexaryEnvelopeTouchedBy(node).chunks, haveNode

        # Import already processed part of the envelope of `node` into the
        # `batch.processed` set of ranges.
        for iv in rp.processed.hexaryEnvelopeTouchedBy(node).increasing:
          let segment = (envelope * iv).value
          discard result[^1].merge segment

          subCount.inc   # dlogging & ebugging
          when extraTraceMessages:
            trace logTxt "history loop => sub", count, subCount,
              touchedLen=segment.fullFactor.toPC(3)

# ------------------------------------------------------------------------------
# Private functions, swap-in functionality
# ------------------------------------------------------------------------------

proc swapIn*(
    pivot: SnapRangeBatchRef;        # Healing state for target hexary trie
    otherPivots: seq[SwapInPivot];   # Other pivots list
    rootKey: NodeKey;                # Start node into target hexary trie
    getFn: HexaryGetFn;              # Abstract database access
    loopMax = 20;                    # Prevent from looping too often
      ): (int,seq[NodeTagRangeSet]) =
  ## Collect processed already ranges from argument `otherPivots` and register
  ## it onto the argument `pivot`. This function recognises and imports
  ## directly accessible sub-tries where the top-level node exists.
  var
    lapCount = 0
    notDoneYet = true
    swappedIn = newSeq[NodeTagRangeSet](otherPivots.len)

  # Initialise return value
  for n in 0 ..< swappedIn.len:
    swappedIn[n] = NodeTagRangeSet.init()

  while notDoneYet and lapCount < loopMax:
    var
      merged = 0.u256
      nCheckNodesBefore = 0 # debugging

    # Decompose `checkNodes` into sub-tries disjunct from `processed`
    let toBeReclassified = block:
      let rc = pivot.decomposeCheckNodes(rootKey, getFn)
      if rc.isErr:
        return (lapCount,swappedIn) # nothing to do
      rc.value

    lapCount.inc
    notDoneYet = false

    # Reclassify nodes into existing/allocated and dangling ones
    noKeyErrorOops("swapIn"):
      var
        checkNodes: seq[NodeSpecs]
        sickNodes: seq[NodeSpecs]
      for node in toBeReclassified:
        # Check whether previously missing nodes from the `sickSubTries` list
        # have been magically added to the database since it was checked last
        # time. These nodes will me moved to `checkNodes` for further
        # processing.
        if node.nodeKey.ByteArray32.getFn().len == 0:
          sickNodes.add node # probably subject to healing
        else:
          let iv = node.hexaryEnvelope
          if pivot.processed.covered(iv) < iv.len:
            checkNodes.add node # may be swapped in
      pivot.checkNodes = checkNodes.hexaryEnvelopeUniq
      pivot.sickSubTries = sickNodes.hexaryEnvelopeUniq

      nCheckNodesBefore = pivot.checkNodes.len # logging & debugging

      # Swap in node ranges from other pivots
      for node in pivot.checkNodes:
        for n,rangeSet in node.otherProcessedRanges(otherPivots,rootKey,getFn):
          for iv in rangeSet.increasing:
            discard swappedIn[n].merge iv        # imported range / other pivot
            merged += pivot.processed.merge iv   # import this range
            pivot.unprocessed.reduce iv          # no need to fetch it again
      notDoneYet = 0 < merged # loop control

      # Remove fully covered nodes
      block:
        var checkNodes: seq[NodeSpecs]
        for node in toBeReclassified:
          let iv = node.hexaryEnvelope
          if pivot.processed.covered(iv) < iv.len:
            checkNodes.add node # may be swapped in
        pivot.checkNodes = checkNodes.hexaryEnvelopeUniq

    when extraTraceMessages:
      let mergedFactor = merged.to(float) / (2.0^256)
      trace logTxt "inherited ranges", nCheckNodesBefore,
        nCheckNodes=pivot.checkNodes.len, merged=mergedFactor.toPC(3)

    # End while()

  (lapCount,swappedIn)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc swapInAccounts*(
    buddy: SnapBuddyRef;               # Worker peer
    env: SnapPivotRef;                 # Current pivot environment
    loopMax = 20;                      # Prevent from looping too often
      ): int =
  ## Variant of `swapIn()` for the particular case of accounts database pivots.
  let
    ctx = buddy.ctx
    rootKey = env.stateHeader.stateRoot.to(NodeKey)
    getFn = ctx.data.snapDb.getAccountFn

    others = toSeq(ctx.data.pivotTable.nextPairs)

                # Swap in from mothballed pifots different from the current one
                .filterIt(it.data.archived and it.key.to(NodeKey) != rootKey)

                # Extract relevant parts
                .mapIt(SwapInPivot(
                  rootKey:   it.key.to(NodeKey),
                  processed: it.data.fetchAccounts.processed,
                  pivot:     it.data))
  var
   nLaps: int
   swappedIn: seq[NodeTagRangeSet]

  noExceptionOops("swapInAccounts"):
    (nLaps,swappedIn) = env.fetchAccounts.swapIn(others,rootKey,getFn,loopMax)

  noKeyErrorOops("swapInAccounts"):
    # Update storage slots
    doAssert swappedIn.len == others.len
    for n in 0 ..< others.len:

      when extraTraceMessages:
        trace logTxt "post-processing storage slots", inx=n, maxInx=others.len,
          changes=swappedIn[n].fullFactor.toPC(3), chunks=swappedIn[n].chunks

      # Revisit all imported account key ranges
      for iv in swappedIn[n].increasing:

        # The `storageAccounts` list contains indices for storage slots, mapping
        # account keys => storage root
        var rc = others[n].pivot.storageAccounts.ge(iv.minPt)
        while rc.isOk and rc.value.key <= iv.maxPt:

          # Fetch storage slots specs from `fetchStorageFull` list
          let stRoot = rc.value.data
          if others[n].pivot.fetchStorageFull.hasKey(stRoot):
            let accKey = others[n].pivot.fetchStorageFull[stRoot].accKey
            discard env.fetchStorageFull.append(
              stRoot, SnapSlotsQueueItemRef(acckey: accKey))

          rc = others[n].pivot.storageAccounts.gt(rc.value.key)

  nLaps

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
