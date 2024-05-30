# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[sequtils, sets, strformat, strutils],
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set],
  results,
  unittest2,
  ../../nimbus/sync/[handlers, protocol, types],
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[
    hexary_debug, hexary_desc, hexary_envelope,  hexary_error,
    hexary_interpolate, hexary_nearby, hexary_paths, hexary_range,
    snapdb_accounts, snapdb_debug, snapdb_desc],
  ../replay/[pp, undump_accounts],
  ./test_helpers

const
  cmaNlSp0 = ",\n" & repeat(" ",12)
  cmaNlSpc = ",\n" & repeat(" ",13)

# ------------------------------------------------------------------------------
# Private functions, pretty printing
# ------------------------------------------------------------------------------

proc ppNodeKeys(a: openArray[SnapProof]; dbg = HexaryTreeDbRef(nil)): string =
  result = "["
  if dbg.isNil:
    result &= a.mapIt(it.to(Blob).digestTo(NodeKey).pp(collapse=true)).join(",")
  else:
    result &= a.mapIt(it.to(Blob).digestTo(NodeKey).pp(dbg)).join(",")
  result &= "]"

proc ppHexPath(p: RPath|XPath; dbg = HexaryTreeDbRef(nil)): string =
  if dbg.isNil:
    "*pretty printing disabled*"
  else:
    p.pp(dbg)

proc pp(a: NodeTag; collapse = true): string =
  a.to(NodeKey).pp(collapse)

proc pp(iv: NodeTagRange; collapse = false): string =
  "(" & iv.minPt.pp(collapse) & "," & iv.maxPt.pp(collapse) & ")"

# ------------------------------------------------------------------------------
# Private functionsto(Blob)
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


proc printCompareRightLeafs(
    rootKey: NodeKey;
    baseTag: NodeTag;
    accounts: seq[PackedAccount];
    leafs: seq[RangeLeaf];
    db: HexaryTreeDbRef|HexaryGetFn;        ## Database abstraction
    dbg: HexaryTreeDbRef;                   ## Debugging env
      ) =
  let
    noisy = not dbg.isNil
  var
    top = 0
    nMax = min(accounts.len, leafs.len)
    step = nMax div 2

  while top < nMax:
    while 1 < step and accounts[top+step].accKey != leafs[top+step].key:
      #noisy.say "***", "i=", top+step, " fail"
      step = max(1, step div 2)

    if accounts[top+step].accKey == leafs[top+step].key:
      top += step
      step = max(1, step div 2)
      noisy.say "***", "i=", top, " step=", step, " ok"
      continue

    let start = top
    top = nMax
    for i in start ..< top:
      if accounts[i].accKey == leafs[i].key:
        noisy.say "***", "i=", i, " skip, ok"
        continue

      # Diagnostics and return
      check (i,accounts[i].accKey) == (i,leafs[i].key)

      let
        lfsKey = leafs[i].key
        accKey = accounts[i].accKey
        prdKey = if 0 < i: accounts[i-1].accKey else: baseTag.to(NodeKey)
        nxtTag = if 0 < i: prdKey.to(NodeTag) + 1.u256 else: baseTag
        nxtPath = nxtTag.hexaryPath(rootKey,db)
        rightRc = nxtPath.hexaryNearbyRight(db)

      if rightRc.isOk:
        check lfsKey == rightRc.value.getPartialPath.convertTo(NodeKey)
      else:
        check rightRc.error == HexaryError(0) # force error printing

      if noisy: true.say "\n***", "i=", i, "/", accounts.len,
        "\n\n    prdKey=", prdKey,
        "\n    ", prdKey.hexaryPath(rootKey,db).pp(dbg),
        "\n\n    nxtKey=", nxtTag,
        "\n    ", nxtPath.pp(dbg),
        "\n\n    accKey=", accKey,
        "\n    ", accKey.hexaryPath(rootKey,db).pp(dbg),
        "\n\n    lfsKey=", lfsKey,
        "\n    ", lfsKey.hexaryPath(rootKey,db).pp(dbg),
        "\n"
      return


proc printCompareLeftNearby(
    rootKey: NodeKey;
    leftKey: NodeKey;
    rightKey: NodeKey;
    db: HexaryTreeDbRef|HexaryGetFn;        ## Database abstraction
    dbg: HexaryTreeDbRef;                   ## Debugging env
      ) =
  let
    noisy = not dbg.isNil
    rightPath = rightKey.hexaryPath(rootKey,db)
    toLeftRc = rightPath.hexaryNearbyLeft(db)
  var
    toLeftKey: NodeKey

  if toLeftRc.isErr:
    check toLeftRc.error == HexaryError(0) # force error printing
  else:
    toLeftKey = toLeftRc.value.getPartialPath.convertTo(NodeKey)
    if toLeftKey == leftKey:
      return

  if noisy: true.say "\n***",
    "    rightKey=", rightKey,
    "\n    ", rightKey.hexaryPath(rootKey,db).pp(dbg),
    "\n\n    leftKey=", leftKey,
    "\n    ", leftKey.hexaryPath(rootKey,db).pp(dbg),
    "\n\n    toLeftKey=", toLeftKey,
    "\n    ", toLeftKey.hexaryPath(rootKey,db).pp(dbg),
    "\n"


proc verifyRangeProof(
    rootKey: NodeKey;
    baseTag: NodeTag;
    leafs: seq[RangeLeaf];
    proof: seq[SnapProof];
    dbg = HexaryTreeDbRef(nil);
    leafBeforeBase = true;
     ): Result[void,HexaryError] =
  ## Re-build temporary database and prove or disprove
  let
    noisy = dbg.isNil.not
    xDb = HexaryTreeDbRef()
  if not dbg.isNil:
    xDb.keyPp = dbg.keyPp

  result = ok()
  block verify:
    let leaf0Tag = leafs[0].key.to(NodeTag)

    # Import proof nodes
    result = xDb.mergeProofs(rootKey, proof)
    if result.isErr:
      check result == Result[void,HexaryError].ok()
      break verify

    # Build tree
    var lItems = leafs.mapIt(RLeafSpecs(
      pathTag: it.key.to(NodeTag),
      payload: it.data))
    result = xDb.hexaryInterpolate(rootKey, lItems)
    if result.isErr:
      check result == Result[void,HexaryError].ok()
      break verify

    # Left proof
    result = xDb.verifyLowerBound(rootKey, baseTag, leaf0Tag)
    if result.isErr:
      check result == Result[void,HexaryError].ok()
      break verify

    # Inflated interval around first point
    block:
      let iv0 = xDb.hexaryRangeInflate(rootKey, leaf0Tag)
      # Verify left end
      if baseTag == low(NodeTag):
        if iv0.minPt != low(NodeTag):
          check iv0.minPt == low(NodeTag)
          result = Result[void,HexaryError].err(NearbyFailed)
          break verify
      elif leafBeforeBase:
        check iv0.minPt < baseTag
      # Verify right end
      if 1 < leafs.len:
        if iv0.maxPt + 1.u256 != leafs[1].key.to(NodeTag):
          check iv0.maxPt + 1.u256 == leafs[1].key.to(NodeTag)
          result = Result[void,HexaryError].err(NearbyFailed)
          break verify

    # Inflated interval around last point
    if 1 < leafs.len:
      let
        uPt = leafs[^1].key.to(NodeTag)
        ivX = xDb.hexaryRangeInflate(rootKey, uPt)
      # Verify left end
      if leafs[^2].key.to(NodeTag) != ivX.minPt - 1.u256:
        check leafs[^2].key.to(NodeTag) == ivX.minPt - 1.u256
        result = Result[void,HexaryError].err(NearbyFailed)
        break verify
      # Verify right end
      if uPt < high(NodeTag):
        let
          uPt1 = uPt + 1.u256
          rx = uPt1.hexaryPath(rootKey,xDb).hexaryNearbyRightMissing(xDb)
          ry = uPt1.hexaryNearbyRight(rootKey, xDb)
        if rx.isErr:
          if ry.isOk:
            check rx.isErr and ry.isErr
            result = Result[void,HexaryError].err(NearbyFailed)
            break verify
        elif rx.value != ry.isErr:
          check rx.value == ry.isErr
          result = Result[void,HexaryError].err(NearbyFailed)
          break verify
        if rx.get(otherwise=false):
          if ivX.minPt + 1.u256 != high(NodeTag):
            check ivX.minPt + 1.u256 == high(NodeTag)
            result = Result[void,HexaryError].err(NearbyFailed)
            break verify

    return ok()

  if noisy:
    true.say "\n***", "error=", result.error,
      #"\n",
      #"\n    unrefs=[", unrefs.toSeq.mapIt(it.pp(dbg)).join(","), "]",
      #"\n    refs=[", refs.toSeq.mapIt(it.pp(dbg)).join(","), "]",
      "\n\n    proof=", proof.ppNodeKeys(dbg),
      "\n\n    first=", leafs[0].key,
      "\n    ", leafs[0].key.hexaryPath(rootKey,xDb).pp(dbg),
      "\n\n    last=", leafs[^1].key,
      "\n    ", leafs[^1].key.hexaryPath(rootKey,xDb).pp(dbg),
      "\n\n    database dump",
      "\n    ", xDb.pp(rootKey),
      "\n"

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

  let
    rootKey = root.to(NodeKey)
    baseTag = accKeys[0].to(NodeTag) + 1.u256
    firstTag = baseTag.hexaryNearbyRight(rootKey, db).get(
                  otherwise = low(NodeTag))
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


proc test_NodeRangeProof*(
    inLst: seq[UndumpAccounts];
    db: HexaryTreeDbRef|HexaryGetFn;         ## Database abstraction
    dbg = HexaryTreeDbRef(nil);              ## Debugging env
      ) =
  ## Partition range and provide proofs suitable for `GetAccountRange` message
  ## from `snap/1` protocol.
  let
    rootKey = inLst[0].root.to(NodeKey)
    noisy = not dbg.isNil
    maxLen = high(int) # set it lower for debugging (eg. 5 for a small smaple)

  # Assuming the `inLst` entries have been stored in the DB already
  for n,w in inLst:
    doAssert 1 < w.data.accounts.len
    let
      first = w.data.accounts[0].accKey.to(NodeTag)
      delta = (w.data.accounts[1].accKey.to(NodeTag) - first) div 2
      # Use the middle of the first two points as base unless w.base is zero.
      # This is needed as the range extractor needs the node before the `base`
      # (if ateher is any) in order to assemble the proof. But this node might
      # not be present in the partial database.
      (base, start) = if w.base == low(NodeTag): (w.base, 0)
                      else: (first + delta, 1)
      # Assemble accounts list starting at the second item
      accounts = w.data.accounts[start ..< min(w.data.accounts.len,maxLen)]
      iv = NodeTagRange.new(base, accounts[^1].accKey.to(NodeTag))
      rc = db.hexaryRangeLeafsProof(rootKey, iv)
    check rc.isOk
    if rc.isErr:
      return

    # Run over sub-samples of the given account range
    var subCount = 0
    for cutOff in {0, 2, 5, 10, 16, 23, 77}:

      # Take sub-samples but not too small
      if 0 < cutOff and rc.value.leafs.len < cutOff + 5:
        break # remaining cases ignored
      subCount.inc

      let
        leafs = rc.value.leafs[0 ..< rc.value.leafs.len - cutOff]
        leafsRlpLen = leafs.encode.len
      var
        proof: seq[SnapProof]

      # Calculate proof
      if cutOff == 0:
        if leafs.len != accounts.len or accounts[^1].accKey != leafs[^1].key:
          noisy.say "***", "n=", n, " something went wrong .."
          check (n,leafs.len) == (n,accounts.len)
          rootKey.printCompareRightLeafs(base, accounts, leafs, db, dbg)
          return
        proof = rc.value.proof

        # Some sizes to verify (full data list)
        check rc.value.proofSize == proof.proofEncode.len
        check rc.value.leafsSize == leafsRlpLen
      else:
        # Make sure that the size calculation delivers the expected number
        # of entries.
        let rx = db.hexaryRangeLeafsProof(rootKey, iv, leafsRlpLen + 1)
        check rx.isOk
        if rx.isErr:
          return
        check rx.value.leafs.len == leafs.len

        # Some size to verify (truncated data list)
        check rx.value.proofSize == rx.value.proof.proofEncode.len

        # Re-adjust proof
        proof = db.hexaryRangeLeafsProof(rootKey, rx.value).proof

      # Import proof nodes and build trie
      block:
        var rx = rootKey.verifyRangeProof(base, leafs, proof)
        if rx.isErr:
          rx = rootKey.verifyRangeProof(base, leafs, proof, dbg)
          let
            baseNbls =  iv.minPt.to(NodeKey).to(NibblesSeq)
            lastNbls =  iv.maxPt.to(NodeKey).to(NibblesSeq)
            nPfxNblsLen = baseNbls.sharedPrefixLen lastNbls
            pfxNbls = baseNbls.slice(0, nPfxNblsLen)
          noisy.say "***", "n=", n,
            " cutOff=", cutOff,
            " leafs=", leafs.len,
            " proof=", proof.ppNodeKeys(dbg),
            "\n\n   ",
            " base=", iv.minPt,
            "\n    ", iv.minPt.hexaryPath(rootKey,db).ppHexPath(dbg),
            "\n\n   ",
            " pfx=", pfxNbls,
            " nPfx=", nPfxNblsLen,
            "\n    ", pfxNbls.hexaryPath(rootKey,db).ppHexPath(dbg),
            "\n"

          check rx == typeof(rx).ok()
          return

    noisy.say "***", "n=", n,
      " leafs=", rc.value.leafs.len,
      " proof=", rc.value.proof.len, "/", w.data.proof.len,
      " sub-samples=", subCount


proc test_NodeRangeLeftBoundary*(
    inLst: seq[UndumpAccounts];
    db: HexaryTreeDbRef|HexaryGetFn;         ## Database abstraction
    dbg = HexaryTreeDbRef(nil);              ## Debugging env
      ) =
  ## Verify left side boundary checks
  let
    rootKey = inLst[0].root.to(NodeKey)
    noisy {.used.} = not dbg.isNil

  # Assuming the `inLst` entries have been stored in the DB already
  for n,w in inLst:
    let accounts = w.data.accounts
    for i in 1 ..< accounts.len:
      let
        leftKey = accounts[i-1].accKey
        rightKey = (accounts[i].accKey.to(NodeTag) - 1.u256).to(NodeKey)
        toLeftRc = rightKey.hexaryPath(rootKey,db).hexaryNearbyLeft(db)
      if toLeftRc.isErr:
        check toLeftRc.error == HexaryError(0) # force error printing
        return
      let toLeftKey = toLeftRc.value.getPartialPath.convertTo(NodeKey)
      if leftKey != toLeftKey:
        let j = i-1
        check (n, j, leftKey) == (n, j, toLeftKey)
        rootKey.printCompareLeftNearby(leftKey, rightKey, db, dbg)
        return
    # noisy.say "***", "n=", n, " accounts=", accounts.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
