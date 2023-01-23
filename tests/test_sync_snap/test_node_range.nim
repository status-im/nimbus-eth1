# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[sequtils, strformat, strutils],
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set, results],
  unittest2,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_envelope, hexary_nearby, hexary_paths]

const
  cmaNlSp0 = ",\n" & repeat(" ",12)
  cmaNlSpc = ",\n" & repeat(" ",13)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc print_data(
    pfx: Blob;
    pfxLen: int;
    ivMin: NibblesSeq;
    firstTag: NodeTag;
    lastTag: NodeTag;
    ivMax: NibblesSeq;
    gaps: NodeTagRangeSet;
    gapPaths: seq[NodeTagRange];
    info: string;
      ) =
  echo ">>>", info, " pfxMax=", pfxLen,
    "\n         pfx=", pfx, "/", ivMin.slice(0,pfxLen).hexPrefixEncode,
    "\n       ivMin=", ivMin,
    "\n    firstTag=", firstTag,
    "\n     lastTag=", lastTag,
    "\n       ivMax=", ivMax,
    "\n     gaps=@[", toSeq(gaps.increasing)
        .mapIt(&"[{it.minPt}{cmaNlSpc}{it.maxPt}]")
        .join(cmaNlSp0), "]",
    "\n gapPaths=@[", gapPaths
        .mapIt(&"[{it.minPt}{cmaNlSpc}{it.maxPt}]")
        .join(cmaNlSp0), "]"


proc print_data(
    pfx: Blob;
    qfx: seq[NodeSpecs];
    iv: NodeTagRange;
    firstTag: NodeTag;
    lastTag: NodeTag;
    rootKey: NodeKey;
    db: HexaryTreeDbRef|HexaryGetFn;
    dbg: HexaryTreeDbRef;
      ) =
  echo "***",
    "\n       qfx=@[", qfx
        .mapIt(&"({it.partialPath.toHex},{it.nodeKey.pp(dbg)})")
        .join(cmaNlSpc), "]",
    "\n     ivMin=", iv.minPt,
    "\n    ", iv.minPt.hexaryPath(rootKey,db).pp(dbg), "\n",
    "\n  firstTag=", firstTag,
    "\n    ", firstTag.hexaryPath(rootKey,db).pp(dbg), "\n",
    "\n   lastTag=", lastTag,
    "\n    ", lastTag.hexaryPath(rootKey,db).pp(dbg), "\n",
    "\n     ivMax=", iv.maxPt,
    "\n    ", iv.maxPt.hexaryPath(rootKey,db).pp(dbg), "\n",
    "\n    pfxMax=", pfx.hexaryEnvelope.maxPt,
    "\n    ", pfx.hexaryEnvelope.maxPt.hexaryPath(rootKey,db).pp(dbg)

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_NodeRangeDecompose*(
    accKeys: seq[NodeKey];                  ## Accounts key range
    root: Hash256;                          ## State root
    db: HexaryTreeDbRef|HexaryGetFn;        ## Database abstraction
    dbg: HexaryTreeDbRef;                   ## Debugging env
      ) =
  ## Testing body for `hexary_nearby` and `hexary_envelope` tests
  # The base data from above cannot be relied upon as there might be
  # stray account nodes in the proof *before* the left boundary.
  doAssert 2 < accKeys.len

  const
    isPersistent = db.type is HexaryTreeDbRef
  let
    rootKey = root.to(NodeKey)
    baseTag = accKeys[0].to(NodeTag) + 1.u256
    firstTag = baseTag.hexaryNearbyRight(rootKey, db).get(
                  otherwise = low(Nodetag))
    lastTag = accKeys[^2].to(NodeTag)
    topTag = accKeys[^1].to(NodeTag) - 1.u256

  # Verify set up
  check baseTag < firstTag
  check firstTag < lastTag
  check lastTag < topTag

  # Verify right boundary proof function (left boundary is
  # correct by definition of `firstTag`.)
  check lastTag == topTag.hexaryNearbyLeft(rootKey, db).get(
    otherwise = high(NodeTag))

  # Construct test range
  let
    iv = NodeTagRange.new(baseTag, topTag)
    ivMin = iv.minPt.to(NodeKey).ByteArray32.toSeq.initNibbleRange
    ivMax = iv.maxPt.to(NodeKey).ByteArray32.toSeq.initNibbleRange
    pfxLen = ivMin.sharedPrefixLen ivMax

  # Use some overlapping prefixes. Note that a prefix must refer to
  # an existing node
  for n in 0 .. pfxLen:
    let
      pfx = ivMin.slice(0, pfxLen - n).hexPrefixEncode
      qfx = block:
        let rc = pfx.hexaryEnvelopeDecompose(rootKey, iv, db)
        check rc.isOk
        if rc.isOk:
          rc.value
        else:
          seq[NodeSpecs].default

    # Assemble possible gaps in decomposed envelope `qfx`
    let gaps = NodeTagRangeSet.init()

    # Start with full envelope and remove decomposed enveloped from `qfx`
    discard gaps.merge pfx.hexaryEnvelope

    # There are no node points between `iv.minPt` (aka base) and the first
    # account `firstTag` and beween `lastTag` and `iv.maxPt`. So only the
    # interval `[firstTag,lastTag]` is to be fully covered by `gaps`.
    block:
      let iw = NodeTagRange.new(firstTag, lastTag)
      check iw.len == gaps.reduce iw

    for w in qfx:
      # The envelope of `w` must be fully contained in `gaps`
      let iw = w.partialPath.hexaryEnvelope
      check iw.len == gaps.reduce iw

    # Remove that space between the start of `iv` and the first account
    # key (if any.).
    if iv.minPt < firstTag:
      discard gaps.reduce(iv.minPt, firstTag-1.u256)

    # There are no node points between `lastTag` and `iv.maxPt`
    if lastTag < iv.maxPt:
      discard gaps.reduce(lastTag+1.u256, iv.maxPt)

    # All gaps must be empty intervals
    var gapPaths: seq[NodeTagRange]
    for w in gaps.increasing:
      let rc = w.minPt.hexaryPath(rootKey,db).hexaryNearbyRight(db)
      if rc.isOk:
        var firstTag = rc.value.getPartialPath.convertTo(NodeTag)

        # The point `firstTag` might be zero if there is a missing node
        # in between to advance to the next key.
        if w.minPt <= firstTag:
          # The interval `w` starts before the first interval
          if firstTag <= w.maxPt:
            # Make sure that there is no leaf node in the range
            gapPaths.add w
          continue

      # Some sub-tries might not exists which leads to gaps
      let
        wMin = w.minPt.to(NodeKey).ByteArray32.toSeq.initNibbleRange
        wMax = w.maxPt.to(NodeKey).ByteArray32.toSeq.initNibbleRange
        nPfx = wMin.sharedPrefixLen wMax
      for nibble in wMin[nPfx] .. wMax[nPfx]:
        let wPfy = wMin.slice(0,nPfx) & @[nibble].initNibbleRange.slice(1)
        if wPfy.hexaryPathNodeKey(rootKey, db, missingOk=true).isOk:
          gapPaths.add wPfy.hexPrefixEncode.hexaryEnvelope

    # Verify :)
    check gapPaths == seq[NodeTagRange].default

    when false: # or true:
      print_data(
        pfx, pfxLen, ivMin, firstTag, lastTag, ivMax, gaps, gapPaths, "n=" & $n)

      print_data(
        pfx, qfx, iv, firstTag, lastTag, rootKey, db, dbg)

      if true: quit()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
