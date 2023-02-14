# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Envelope tools for nodes and hex encoded *partial paths*
## ========================================================
##
## Envelope
## --------
## Given a hex encoded *partial path*, this is the maximum range of leaf node
## paths (of data type `NodeTag`) that starts with the *partial path*. It is
## obtained by creating an interval (of type `NodeTagRange`) with end points
## starting with the *partial path* and extening it with *zero* nibbles for
## the left end, and *0xf* nibbles for the right end.
##
## Boundary proofs
## ---------------
## The *boundary proof* for a range `iv` of leaf node paths (e.g. account
## hashes) for a given *state root* is a set of nodes enough to construct the
## partial *Merkel Patricia trie* containing the leafs. If the given range
## `iv` is larger than the left or right most leaf node paths, the *boundary
## proof* also implies that there is no other leaf path between the range
## boundary and the left or rightmost leaf path. There is not minimalist
## requirement of a *boundary proof*.
##
## Envelope decomposition
## ----------------------
## The idea is to compute the difference of the envelope of a hex encoded
## *partial path* off some range of leaf node paths and express the result as
## a list of envelopes (represented by either nodes or *partial paths*.)
##
## Prerequisites
## ^^^^^^^^^^^^^
## More formally, assume
##
## * ``partialPath`` is a hex encoded *partial path* (of type ``Blob``)
##
## * ``iv`` is a range of leaf node paths (of type ``NodeTagRange``)
##
## and assume further that
##
## * ``partialPath`` points to an allocated node
##
## * for `iv` there are left and right *boundary proofs in the database
##   (e.g. as downloaded via the `snap/1` protocol.)
##
## The decomposition
## ^^^^^^^^^^^^^^^^^
## Then there is a (probably empty) set `W` of *partial paths* (represented by
## nodes or *partial paths*) where the envelope of each *partial path* in `W`
## has no common leaf path in `iv` (i.e. disjunct to the sub-range of `iv`
## where the boundaries are existing node keys.)
##
## Let this set `W` be maximal in the sense that for every *partial path* `p`
## which is prefixed by `partialPath` the envelope of which has no common leaf
## node in `iv` there exists a *partial path* `w` in `W` that prefixes `p`. In
## other words the envelope of `p` is contained in the envelope of `w`.
##
## Formally:
##
## * if ``p = partialPath & p-ext`` with ``(envelope of p) * iv`` has no
##   allocated nodes for in the hexary trie database
##
## * then there is a ``w = partialPath & w-ext`` in ``W`` with
##   ``p-ext = w-ext & some-ext``.
##
import
  std/[algorithm, sequtils, tables],
  eth/[common, trie/nibbles],
  stew/interval_set,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_nearby, hexary_paths]

{.push raises: [].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `==`(a, b: XNodeObj): bool =
  if a.kind == b.kind:
    case a.kind:
    of Leaf:
      return a.lPfx == b.lPfx and a.lData == b.lData
    of Extension:
      return a.ePfx == b.ePfx and a.eLink == b.eLink
    of Branch:
      return a.bLink == b.bLink

proc eq(a, b: XPathStep|RPathStep): bool =
  a.key == b.key and a.nibble == b.nibble and a.node == b.node


proc isZeroLink(a: Blob): bool =
  ## Persistent database has `Blob` as key
  a.len == 0

proc isZeroLink(a: RepairKey): bool =
  ## Persistent database has `RepairKey` as key
  a.isZero

proc convertTo(key: RepairKey; T: type NodeKey): T =
  ## Might be lossy, check before use
  discard result.init(key.ByteArray33[1 .. 32])

proc toNodeSpecs(nodeKey: RepairKey; partialPath: Blob): NodeSpecs =
  NodeSpecs(
    nodeKey:     nodeKey.convertTo(NodeKey),
    partialPath: partialPath)

proc toNodeSpecs(nodeKey: Blob; partialPath: Blob): NodeSpecs =
  NodeSpecs(
    nodeKey:     nodeKey.convertTo(NodeKey),
    partialPath: partialPath)


template noKeyErrorOops(info: static[string]; code: untyped) =
  try:
    code
  except KeyError as e:
    raiseAssert "Impossible KeyError (" & info & "): " & e.msg

template noRlpErrorOops(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert "Impossible RlpError (" & info & "): " & e.msg

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc padPartialPath(pfx: NibblesSeq; dblNibble: byte): NodeKey =
  ## Extend (or cut) `partialPath` nibbles sequence and generate `NodeKey`
  # Pad with zeroes
  var padded: NibblesSeq

  let padLen = 64 - pfx.len
  if 0 <= padLen:
    padded = pfx & dblNibble.repeat(padlen div 2).initNibbleRange
    if (padLen and 1) == 1:
      padded = padded & @[dblNibble].initNibbleRange.slice(1)
  else:
    let nope = seq[byte].default.initNibbleRange
    padded = pfx.slice(0,64) & nope # nope forces re-alignment

  let bytes = padded.getBytes
  (addr result.ByteArray32[0]).copyMem(unsafeAddr bytes[0], bytes.len)


proc doDecomposeLeft(
    envQ: RPath|XPath;
    ivQ: RPath|XPath;
      ): Result[seq[NodeSpecs],HexaryError] =
  ## Helper for `hexaryEnvelopeDecompose()` for handling left side of
  ## envelope from partial path argument
  #
  #              partialPath
  #               /      \
  #              /        \
  #   ivQ[x]==envQ[x]      \       -- envelope left end of partial path
  #     |                   \
  #   ivQ[x+1]                     -- `iv`, not fully covering left of `env`
  #     :
  #
  var collect: seq[NodeSpecs]
  block rightCurbEnvelope:
    for n in 0 ..< min(envQ.path.len+1, ivQ.path.len):
      if n == envQ.path.len or not envQ.path[n].eq(ivQ.path[n]):
        #
        # At this point, the `node` entries of either `.path[n]` step are
        # the same. This is so because the predecessor steps were the same
        # or were the `rootKey` in case n == 0.
        #
        # But then (`node` entries being equal) the only way for the `.path[n]`
        # steps to differ is in the entry selector `nibble` for a branch node.
        #
        for m in n ..< ivQ.path.len:
          let
            pfx = ivQ.getNibbles(0, m) # common path segment
            top = ivQ.path[m].nibble   # need nibbles smaller than top
          #
          # Incidentally for a non-`Branch` node, the value `top` becomes
          # `-1` and the `for`- loop will be ignored (which is correct)
          for nibble in 0 ..< top:
            let nodeKey = ivQ.path[m].node.bLink[nibble]
            if not nodeKey.isZeroLink:
              collect.add nodeKey.toNodeSpecs hexPrefixEncode(
                pfx & @[nibble.byte].initNibbleRange.slice(1),isLeaf=false)
        break rightCurbEnvelope
    #
    # Fringe case, e.g. when `partialPath` is an empty prefix (aka `@[0]`)
    # and the database has a single leaf node `(a,some-value)` where the
    # `rootKey` is the hash of this node. In that case, `pMin == 0` and
    # `pMax == high(NodeTag)` and `iv == [a,a]`.
    #
    return err(DecomposeDegenerated)

  ok(collect)

proc doDecomposeRight(
    envQ: RPath|XPath;
    ivQ: RPath|XPath;
      ): Result[seq[NodeSpecs],HexaryError] =
  ## Helper for `hexaryEnvelopeDecompose()` for handling right side of
  ## envelope from partial path argument
  #
  #      partialPath
  #       /        \
  #      /          \
  #     /  ivQ[x]==envQ[^1]     -- envelope right end of partial path
  #    /     |
  #        ivQ[x+1]             -- `iv`, not fully covering right of `env`
  #          :
  #
  var collect: seq[NodeSpecs]
  block leftCurbEnvelope:
    for n in 0 ..< min(envQ.path.len+1, ivQ.path.len):
      if n == envQ.path.len or not envQ.path[n].eq(ivQ.path[n]):
        for m in n ..< ivQ.path.len:
          let
            pfx = ivQ.getNibbles(0, m) # common path segment
            base = ivQ.path[m].nibble  # need nibbles greater/equal
          if 0 <= base:
            for nibble in base+1 .. 15:
              let nodeKey = ivQ.path[m].node.bLink[nibble]
              if not nodeKey.isZeroLink:
                collect.add nodeKey.toNodeSpecs hexPrefixEncode(
                  pfx & @[nibble.byte].initNibbleRange.slice(1),isLeaf=false)
        break leftCurbEnvelope
    return err(DecomposeDegenerated)

  ok(collect)


proc decomposeLeftImpl(
    env: NodeTagRange;               # Envelope for some partial path
    rootKey: NodeKey;                # State root
    iv: NodeTagRange;                # Proofed range of leaf paths
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Database agnostic implementation of `hexaryEnvelopeDecompose()`.
  var nodeSpex: seq[NodeSpecs]

  # So ranges do overlap. The case that the `partialPath` envelope is fully
  # contained in `iv` results in `@[]` which is implicitely handled by
  # non-matching of the below if clause.
  if env.minPt < iv.minPt:
    let
      envQ = env.minPt.hexaryPath(rootKey, db)
      # Make sure that the min point is the nearest node to the right
      ivQ = block:
        let rc = iv.minPt.hexaryPath(rootKey, db).hexaryNearbyRight(db)
        if rc.isErr:
          return err(rc.error)
        rc.value
    block:
      let rc = envQ.doDecomposeLeft ivQ
      if rc.isErr:
        return err(rc.error)
      nodeSpex &= rc.value

  ok(nodeSpex)


proc decomposeRightImpl(
    env: NodeTagRange;               # Envelope for some partial path
    rootKey: NodeKey;                # State root
    iv: NodeTagRange;                # Proofed range of leaf paths
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Database agnostic implementation of `hexaryEnvelopeDecompose()`.
  var nodeSpex: seq[NodeSpecs]
  if iv.maxPt < env.maxPt:
    let
      envQ = env.maxPt.hexaryPath(rootKey, db)
      ivQ = block:
        let rc = iv.maxPt.hexaryPath(rootKey, db).hexaryNearbyLeft(db)
        if rc.isErr:
          return err(rc.error)
        rc.value
    block:
      let rc = envQ.doDecomposeRight ivQ
      if rc.isErr:
        return err(rc.error)
      nodeSpex &= rc.value

  ok(nodeSpex)

# ------------------------------------------------------------------------------
# Public functions, envelope constructor
# ------------------------------------------------------------------------------

proc hexaryEnvelope*(partialPath: Blob): NodeTagRange =
  ## Convert partial path to range of all concievable node keys starting with
  ## the partial path argument `partialPath`.
  let pfx = partialPath.hexPrefixDecode[1]
  NodeTagRange.new(
    pfx.padPartialPath(0).to(NodeTag),
    pfx.padPartialPath(255).to(NodeTag))

proc hexaryEnvelope*(node: NodeSpecs): NodeTagRange =
  ## variant of `hexaryEnvelope()`
  node.partialPath.hexaryEnvelope()

# ------------------------------------------------------------------------------
# Public functions, helpers
# ------------------------------------------------------------------------------

proc hexaryEnvelopeUniq*(
    partialPaths: openArray[Blob];
      ): seq[Blob]
      {.gcsafe, raises: [KeyError].} =
  ## Sort and simplify a list of partial paths by sorting envelopes while
  ## removing nested entries.
  if partialPaths.len < 2:
    return partialPaths.toSeq

  var tab: Table[NodeTag,(Blob,bool)]
  for w in partialPaths:
    let iv = w.hexaryEnvelope
    tab[iv.minPt] = (w,true)    # begin entry
    tab[iv.maxPt] = (@[],false) # end entry

  # When sorted, nested entries look like
  #
  # 123000000.. (w0, true)
  # 123400000.. (w1, true)  <--- nested
  # 1234fffff..  (, false)  <--- nested
  # 123ffffff..  (, false)
  # ...
  # 777000000.. (w2, true)
  #
  var level = 0
  for key in toSeq(tab.keys).sorted(cmp):
    let (w,begin) = tab[key]
    if begin:
      if level == 0:
        result.add w
      level.inc
    else:
      level.dec

proc hexaryEnvelopeUniq*(
    nodes: openArray[NodeSpecs];
      ): seq[NodeSpecs]
      {.gcsafe, raises: [KeyError].} =
  ## Variant of `hexaryEnvelopeUniq` for sorting a `NodeSpecs` list by
  ## partial paths.
  if nodes.len < 2:
    return nodes.toSeq

  var tab: Table[NodeTag,(NodeSpecs,bool)]
  for w in nodes:
    let iv = w.partialPath.hexaryEnvelope
    tab[iv.minPt] = (w,true)            # begin entry
    tab[iv.maxPt] = (NodeSpecs(),false) # end entry

  var level = 0
  for key in toSeq(tab.keys).sorted(cmp):
    let (w,begin) = tab[key]
    if begin:
      if level == 0:
        result.add w
      level.inc
    else:
      level.dec


proc hexaryEnvelopeTouchedBy*(
    rangeSet: NodeTagRangeSet;          # Set of intervals (aka ranges)
    partialPath: Blob;                  # Partial path for some node
      ): NodeTagRangeSet =
  ## For the envelope interval of the `partialPath` argument, this function
  ## returns the complete set of intervals from the argument set `rangeSet`
  ## that have a common point with the envelope (i.e. they are non-disjunct to
  ## the envelope.)
  ##
  ## Note that this function always returns a new set (which might be equal to
  ## the argument set `rangeSet`.)
  let probe = partialPath.hexaryEnvelope

  # `probe.len==0`(mod 2^256) => `probe==[0,high]` as `probe` cannot be empty
  if probe.len == 0:
    return rangeSet.clone

  result = NodeTagRangeSet.init() # return empty set unless coverage

  if 0 < rangeSet.covered probe:
    # Find an interval `start` that starts before the `probe` interval.
    # Preferably, this interval is the rightmost one starting before `probe`.
    var startSearch = low(NodeTag)

    # Try least interval starting within or to the right of `probe`.
    let rc = rangeSet.ge probe.minPt
    if rc.isOk:
      # Try predecessor
      let rx = rangeSet.le rc.value.minPt
      if rx.isOk:
        # Predecessor interval starts before `probe`, e.g.
        #
        #  .. [..rx..] [..rc..] ..
        #        [..probe..]
        #
        startSearch = rx.value.minPt
      else:
        # No predecessor, so `rc.value` is the very first interval, e.g.
        #
        #              [..rc..] ..
        #        [..probe..]
        #
        startSearch = rc.value.minPt
    else:
      # No interval starts in or after `probe`.
      #
      # So, if an interval ends before the right end of `probe`, it must
      # start before `probe`.
      let rx = rangeSet.le probe.maxPt
      if rx.isOk:
        #
        #  .. [..rx..] ..
        #        [..probe..]
        #
        startSearch = rx.value.minPt
      else:
        # Otherwise there is no interval preceding `probe`, so the zero
        # value for `start` will do the job, e.g.
        #
        #      [.....rx......]
        #        [..probe..]
        discard

    # Collect intervals left-to-right for non-disjunct to `probe`
    for w in increasing[NodeTag,UInt256](rangeSet, startSearch):
      if (w * probe).isOk:
        discard result.merge w
      elif probe.maxPt < w.minPt:
        break # all the `w` following will be disjuct, too
    # End if


proc hexaryEnvelopeTouchedBy*(
    rangeSet: NodeTagRangeSet;          # Set of intervals (aka ranges)
    node: NodeSpecs;                    # Node w/hex encoded partial path
      ): NodeTagRangeSet =
  ## Variant of `hexaryEnvelopeTouchedBy()`
  rangeSet.hexaryEnvelopeTouchedBy(node.partialPath)

# ------------------------------------------------------------------------------
# Public functions, complement sub-tries
# ------------------------------------------------------------------------------

proc hexaryEnvelopeDecompose*(
    partialPath: Blob;                  # Hex encoded partial path
    rootKey: NodeKey;                   # State root
    iv: NodeTagRange;                   # Proofed range of leaf paths
    db: HexaryTreeDbRef|HexaryGetFn;    # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## This function computes the decomposition of the argument `partialPath`
  ## relative to the argument range `iv`.
  ##
  ## * Comparison with `hexaryInspect()`
  ##
  ##   The function `hexaryInspect()` implements a width-first search for
  ##   dangling nodes starting at the state root (think of the cathode ray of
  ##   a CRT.) For the sake of comparison with `hexaryEnvelopeDecompose()`, the
  ##   search may be amended to ignore nodes the envelope of is fully contained
  ##   in some range `iv`. For a fully allocated hexary trie, there will be at
  ##   least one sub-trie of length *N* with leafs not in `iv`. So the number
  ##   of nodes visited is *O(16^N)* for some *N* at most 63 (note that *N*
  ##   itself is *O(log M)* where M is the size of the leaf elements *M*, and
  ##   *O(16^N)* = *O(M)*.)
  ##
  ##   The function `hexaryEnvelopeDecompose()` take the left or rightmost leaf
  ##   path from `iv`, calculates a chain length *N* of nodes from the state
  ##   root to the leaf, and for each node collects the links not pointing
  ##   inside the range `iv`. The number of nodes visited is *O(N)*.
  ##
  ##   The results of both functions are not interchangeable, though. The first
  ##   function `hexaryInspect()`, always returns dangling nodes if there are
  ##   any in which case the hexary trie is incomplete and there will be no way
  ##   to visit all nodes as they simply do not exist. But iteratively adding
  ##   nodes or sub-tries and re-running this algorithm will end up with having
  ##   all nodes visited.
  ##
  ##   The other function `hexaryEnvelopeDecompose()` always returns the same
  ##   result where some nodes might be dangling and may be treated similar to
  ##   what was discussed in the previous paragraph. This function also reveals
  ##   allocated nodes which might be checked for whether they exist fully or
  ##   partially for another state root hexary trie.
  ##
  ##   So both are sort of complementary where the function
  ##   `hexaryEnvelopeDecompose()` is a fast one and `hexaryInspect()` the
  ##   thorough one of last resort.
  ##
  let env = partialPath.hexaryEnvelope
  if iv.maxPt < env.minPt or env.maxPt < iv.minPt:
    return err(DecomposeDisjunct) # empty result

  noRlpErrorOops("hexaryEnvelopeDecompose"):
    let left = block:
      let rc = env.decomposeLeftImpl(rootKey, iv, db)
      if rc.isErr:
        return rc
      rc.value
    let right = block:
      let rc = env.decomposeRightImpl(rootKey, iv, db)
      if rc.isErr:
        return rc
      rc.value
    return ok(left & right)
  # Notreached


proc hexaryEnvelopeDecompose*(
    partialPath: Blob;               # Hex encoded partial path
    ranges: NodeTagRangeSet;         # To be complemented
    rootKey: NodeKey;                # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError] =
  ## Variant of `hexaryEnvelopeDecompose()` for an argument set `ranges` of
  ## intervals rather than a single one.
  ##
  ## Given that for the arguement `partialPath` there is an allocated node,
  ## and all intervals in the `ranges` argument are boundary proofed, then
  ## this function compiles the complement of the union of the interval
  ## elements `ranges` relative to the envelope of the argument `partialPath`.
  ## The function expresses this complement as a list of envelopes of
  ## sub-tries. In other words, it finds a list `L` with
  ##
  ## * ``L`` is a list of (existing but not necessarily allocated) nodes.
  ##
  ## * The union ``U(L)`` of envelopes of elements of ``L`` is a subset of the
  ##   envelope ``E(partialPath)`` of ``partialPath``.
  ##
  ## * ``U(L)`` has no common point with any interval of the set ``ranges``.
  ##
  ## * ``L`` is maximal in the sense that any node ``w`` which is prefixed by
  ##   a node from ``E(partialPath)`` and with an envelope ``E(w)`` without
  ##   common node for any interval of ``ranges`` is also prefixed by a node
  ##   from ``L``.
  ##
  ## * The envelopes of the nodes in ``L`` are disjunct (i.e. the size of `L`
  ##   is minimal.)
  ##
  ## The function fails if `E(partialPath)` is disjunct from any interval of
  ## `ranges`. The function returns an empty list if `E(partialPath)` overlaps
  ## with some interval from `ranges` but there exists no common nodes. Nodes
  ## that cause *RLP* decoding errors are ignored and will get lost.
  ##
  ## Note: Two intervals over the set of nodes might not be disjunct but
  ##       nevertheless have no node in common simply fot the fact that thre
  ##       are no such nodes in the database (with a path in the intersection
  ##       of the two intervals.)
  ##
  # Find all intervals from the set of `ranges` ranges that have a point
  # in common with `partialPath`.
  let touched = ranges.hexaryEnvelopeTouchedBy partialPath
  if touched.chunks == 0:
    return err(DecomposeDisjunct)

  # Decompose the the complement of the `node` envelope off `iv` into
  # envelopes/sub-tries.
  let
    startNode = NodeSpecs(partialPath: partialPath)
  var
    leftQueue: seq[NodeSpecs]      # To be appended only in loop below
    rightQueue = @[startNode]      # To be replaced/modified in loop below

  for iv in touched.increasing:
    #
    # For the interval `iv` and the list `rightQueue`, the following holds:
    # * `iv` is larger (to the right) of its predecessor `iu` (if any)
    # * all nodes `w` of the list `rightQueue` are larger than `iu` (if any)
    #
    # So collect all intervals to the left `iv` and keep going with the
    # remainder to the right:
    # ::
    #   before decomposing:
    #   v---------v  v---------v    v--------v      -- right queue envelopes
    #         |-----------|                         -- iv
    #
    #   after decomposing the right queue:
    #   v---v                                       -- left queue envelopes
    #                     v----v    v--------v      -- right queue envelopes
    #        |-----------|                          -- iv
    #
    var delayed: seq[NodeSpecs]
    for n,w in rightQueue:

      let env = w.hexaryEnvelope
      if env.maxPt < iv.minPt:
        leftQueue.add w            # Envelope fully to the left of `iv`
        continue

      if iv.maxPt < env.minPt:
        # All remaining entries are fullly to the right of `iv`.
        delayed &= rightQueue[n ..< rightQueue.len]
        # Node that `w` != `startNode` because otherwise `touched` would
        # have been empty.
        break

      try:
        block:
          let rc = env.decomposeLeftImpl(rootKey, iv, db)
          if rc.isOk:
            leftQueue &= rc.value    # Queue left side smaller than `iv`
        block:
          let rc = env.decomposeRightImpl(rootKey, iv, db)
          if rc.isOk:
            delayed &= rc.value      # Queue right side for next lap
      except CatchableError:
        # Cannot decompose `w`, so just drop it
        discard

    # At this location in code, `delayed` can never contain `startNode` as it
    # is decomosed in the algorithm above.
    rightQueue = delayed

    # End for() loop over `touched`

  ok(leftQueue & rightQueue)


proc hexaryEnvelopeDecompose*(
    node: NodeSpecs;                 # The envelope of which to be complemented
    ranges: NodeTagRangeSet;         # To be complemented
    rootKey: NodeKey;                # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `hexaryEnvelopeDecompose()` for ranges and a `NodeSpecs`
  ## argument rather than a partial path.
  node.partialPath.hexaryEnvelopeDecompose(ranges, rootKey, db)

proc hexaryEnvelopeDecompose*(
    ranges: NodeTagRangeSet;         # To be complemented
    rootKey: NodeKey;                # State root
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [CatchableError].} =
  ## Variant of `hexaryEnvelopeDecompose()` for ranges and an implicit maximal
  ## partial path envelope.
  ## argument rather than a partial path.
  @[0.byte].hexaryEnvelopeDecompose(ranges, rootKey, db)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
