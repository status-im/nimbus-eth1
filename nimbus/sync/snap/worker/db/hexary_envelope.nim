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
## and assume further that for `iv` there are left and right *boundary proofs*
## in the database (e.g. as downloaded via the `snap/1` protocol.)
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
## Relation to boundary proofs
## ^^^^^^^^^^^^^^^^^^^^^^^^^^^
## Consider the decomposition of an empty *partial path* (the envelope of which
## representing the whole leaf node path range) for a leaf node range `iv`.
## This result is then a `boundary proof` for `iv` according to the definition
## above though it is highly redundant. All *partial path* bottom level nodes
## with envelopes disjunct to `iv` can be removed from `W` for a `boundary
## proof`.
##
import
  std/[algorithm, sequtils, tables],
  eth/[common, trie/nibbles],
  stew/interval_set,
  ../../range_desc,
  "."/[hexary_desc, hexary_error, hexary_nearby, hexary_paths]

{.push raises: [Defect].}

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
    padded = pfx.slice(0,63) & nope # nope forces re-alignment

  let bytes = padded.getBytes
  (addr result.ByteArray32[0]).copyMem(unsafeAddr bytes[0], bytes.len)


proc decomposeLeft(
    envPt: RPath|XPath;
    ivPt: RPath|XPath;
      ): Result[seq[NodeSpecs],HexaryError] =
  ## Helper for `hexaryEnvelopeDecompose()` for handling left side of
  ## envelope from partial path argument
  #
  #      partialPath
  #       /     \
  #      /       \
  #    envPt..              -- envelope left end of partial path
  #        |
  #      ivPt..             -- `iv`, not fully covering left of `env`
  #
  var collect: seq[NodeSpecs]
  block rightCurbEnvelope:
    for n in 0 ..< min(envPt.path.len+1, ivPt.path.len):
      if n == envPt.path.len or envPt.path[n] != ivPt.path[n]:
        #
        # At this point, the `node` entries of either `path[n]` step are
        # the same. This is so because the predecessor steps were the same
        # or were the `rootKey` in case n == 0.
        #
        # But then (`node` entries being equal) the only way for the
        # `path[n]` steps to differ is in the entry selector `nibble` for
        # a branch node.
        #
        for m in n ..< ivPt.path.len:
          let
            pfx = ivPt.getNibbles(0, m) # common path segment
            top = ivPt.path[m].nibble   # need nibbles smaller than top
          #
          # Incidentally for a non-`Branch` node, the value `top` becomes
          # `-1` and the `for`- loop will be ignored (which is correct)
          for nibble in 0 ..< top:
            let nodeKey = ivPt.path[m].node.bLink[nibble]
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

proc decomposeRight(
    envPt: RPath|XPath;
    ivPt: RPath|XPath;
      ): Result[seq[NodeSpecs],HexaryError] =
  ## Helper for `hexaryEnvelopeDecompose()` for handling right side of
  ## envelope from partial path argument
  #
  #        partialPath
  #         /     \
  #        /       \
  #           .. envPt     -- envelope right end of partial path
  #              |
  #          .. ivPt       -- `iv`, not fully covering right of `env`
  #
  var collect: seq[NodeSpecs]
  block leftCurbEnvelope:
    for n in 0 ..< min(envPt.path.len+1, ivPt.path.len):
      if n == envPt.path.len or envPt.path[n] != ivPt.path[n]:
        for m in n ..< ivPt.path.len:
          let
            pfx = ivPt.getNibbles(0, m) # common path segment
            base = ivPt.path[m].nibble  # need nibbles greater/equal
          if 0 <= base:
            for nibble in base+1 .. 15:
              let nodeKey = ivPt.path[m].node.bLink[nibble]
              if not nodeKey.isZeroLink:
                collect.add nodeKey.toNodeSpecs hexPrefixEncode(
                  pfx & @[nibble.byte].initNibbleRange.slice(1),isLeaf=false)
        break leftCurbEnvelope
    return err(DecomposeDegenerated)

  ok(collect)


proc decomposeImpl(
    partialPath: Blob;               # Hex encoded partial path
    rootKey: NodeKey;                # State root
    iv: NodeTagRange;                # Proofed range of leaf paths
    db: HexaryGetFn|HexaryTreeDbRef; # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [Defect,RlpError,KeyError].} =
  ## Database agnostic implementation of `hexaryEnvelopeDecompose()`.
  let env = partialPath.hexaryEnvelope
  if iv.maxPt < env.minPt or env.maxPt < iv.minPt:
    return err(DecomposeDisjuct) # empty result

  var nodeSpex: seq[NodeSpecs]

  # So ranges do overlap. The case that the `partialPath` envelope is fully
  # contained in `iv` results in `@[]` which is implicitely handled by
  # non-matching any of the cases, below.
  if env.minPt < iv.minPt:
    let
      envPt = env.minPt.hexaryPath(rootKey, db)
      # Make sure that the min point is the nearest node to the right
      ivPt = block:
        let rc = iv.minPt.hexaryPath(rootKey, db).hexaryNearbyRight(db)
        if rc.isErr:
          return err(rc.error)
        rc.value
    block:
      let rc = envPt.decomposeLeft ivPt
      if rc.isErr:
        return err(rc.error)
      nodeSpex &= rc.value

  if iv.maxPt < env.maxPt:
    let
      envPt = env.maxPt.hexaryPath(rootKey, db)
      ivPt = block:
        let rc = iv.maxPt.hexaryPath(rootKey, db).hexaryNearbyLeft(db)
        if rc.isErr:
          return err(rc.error)
        rc.value
    block:
      let rc = envPt.decomposeRight ivPt
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
      {.gcsafe, raises: [Defect,KeyError].} =
  ## Sort and simplify a list of partial paths by sorting envelopes while
  ## removing nested entries.
  var tab: Table[NodeTag,(Blob,bool)]

  for w in partialPaths:
    let iv = w.hexaryEnvelope
    tab[iv.minPt] = (w,true)    # begin entry
    tab[iv.maxPt] = (@[],false) # end entry

  # When sorted, nested entries look like
  #
  # 123000000.. (w0, true)
  # 123400000.. (w1, true)
  # 1234fffff..  (, false)
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
      {.gcsafe, raises: [Defect,KeyError].} =
  ## Variant of `hexaryEnvelopeUniq` for sorting a `NodeSpecs` list by
  ## partial paths.
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
  result = NodeTagRangeSet.init()
  let probe = partialPath.hexaryEnvelope

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
    partialPath: Blob;             # Hex encoded partial path
    rootKey: NodeKey;              # State root
    iv: NodeTagRange;              # Proofed range of leaf paths
    db: HexaryTreeDbRef;           # Database
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [Defect,KeyError].} =
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
  ##   of nodes visited is *O(16^N)* for some *N* at most 63.
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
  noRlpErrorOops("in-memory hexaryEnvelopeDecompose"):
    return partialPath.decomposeImpl(rootKey, iv, db)

proc hexaryEnvelopeDecompose*(
    partialPath: Blob;             # Hex encoded partial path
    rootKey: NodeKey;              # State root
    iv: NodeTagRange;              # Proofed range of leaf paths
    getFn: HexaryGetFn;            # Database abstraction
      ): Result[seq[NodeSpecs],HexaryError]
      {.gcsafe, raises: [Defect,RlpError].} =
  ## Variant of `decompose()` for persistent database.
  noKeyErrorOops("persistent hexaryEnvelopeDecompose"):
    return partialPath.decomposeImpl(rootKey, iv, getFn)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
