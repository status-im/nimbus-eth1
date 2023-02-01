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
  std/[sequtils, sets, strformat, strutils],
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set, results],
  unittest2,
  ../../nimbus/sync/types,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_envelope,  hexary_error, hexary_interpolate,
    hexary_import, hexary_nearby, hexary_paths, hexary_range,
    snapdb_accounts, snapdb_desc],
  ../replay/[pp, undump_accounts],
  ./test_helpers

const
  cmaNlSp0 = ",\n" & repeat(" ",12)
  cmaNlSpc = ",\n" & repeat(" ",13)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc ppNodeKeys(a: openArray[Blob], dbg = HexaryTreeDbRef(nil)): string =
  result = "["
  if dbg.isNil:
    result &= a.mapIt(it.digestTo(NodeKey).pp(collapse=true)).join(",")
  else:
    result &= a.mapIt(it.digestTo(NodeKey).pp(dbg)).join(",")
  result &= "]"

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
    leafs: seq[RangeLeaf];
    proof: seq[Blob];
    dbg = HexaryTreeDbRef(nil);
     ): Result[void,HexaryError] =
  ## Re-build temporary database and prove or disprove
  let
    dumpOk = dbg.isNil.not
    noisy = dbg.isNil.not
    xDb = HexaryTreeDbRef()
  if not dbg.isNil:
    xDb.keyPp = dbg.keyPp

  # Import proof nodes
  var unrefs, refs: HashSet[RepairKey] # values ignored
  for rlpRec in proof:
    let importError = xDb.hexaryImport(rlpRec, unrefs, refs).error
    if importError != HexaryError(0):
      check importError == HexaryError(0)
      return err(importError)

  # Build tree
  var lItems = leafs.mapIt(RLeafSpecs(
    pathTag: it.key.to(NodeTag),
    payload: it.data))
  let rc = xDb.hexaryInterpolate(rootKey, lItems)
  if rc.isOk:
    return ok()

  if noisy:
    true.say "\n***", "error=", rc.error,
      #"\n",
      #"\n    unrefs=[", unrefs.toSeq.mapIt(it.pp(dbg)).join(","), "]",
      #"\n    refs=[", refs.toSeq.mapIt(it.pp(dbg)).join(","), "]",
      "\n\n    proof=", proof.ppNodeKeys(dbg),
      "\n\n    first=", leafs[0].key,
      "\n    ", leafs[0].key.hexaryPath(rootKey,xDb).pp(dbg),
      "\n\n    last=", leafs[^1].key,
      "\n    ", leafs[^1].key.hexaryPath(rootKey,xDb).pp(dbg),
      "\n\n    database dump",
      "\n    ", xDb.dumpHexaDB(rootKey),
      "\n"
  rc

# ------------------------------------------------------------------------------
# Private functions, pretty printing
# ------------------------------------------------------------------------------

proc pp(a: NodeTag; collapse = true): string =
  a.to(NodeKey).pp(collapse)

proc pp(iv: NodeTagRange; collapse = false): string =
  "(" & iv.minPt.pp(collapse) & "," & iv.maxPt.pp(collapse) & ")"

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
    maxLen = high(int)

  # Assuming the `inLst` entries have been stored in the DB already
  for n,w in inLst:
    let
      accounts = w.data.accounts[0 .. min(w.data.accounts.len,maxLen)-1]
      iv = NodeTagRange.new(w.base, accounts[^1].accKey.to(NodeTag))
      rc = iv.hexaryRangeLeafsProof(rootKey, db, accounts.len)
    check rc.isOk
    if rc.isErr:
      return

    let leafs = rc.value.leafs
    if leafs.len != accounts.len or accounts[^1].accKey != leafs[^1].key:
      noisy.say "***", "n=", n, " something went wrong .."
      check (n,leafs.len) == (n,accounts.len)
      rootKey.printCompareRightLeafs(w.base, accounts, leafs, db, dbg)
      return

    # Import proof nodes and build trie
    var rx = rootKey.verifyRangeProof(leafs, rc.value.proof)
    if rx.isErr:
      rx = rootKey.verifyRangeProof(leafs, rc.value.proof, dbg)
      let
        baseNbls =  iv.minPt.to(NodeKey).to(NibblesSeq)
        lastNbls =  iv.maxPt.to(NodeKey).to(NibblesSeq)
        nPfxNblsLen = baseNbls.sharedPrefixLen lastNbls
        pfxNbls = baseNbls.slice(0, nPfxNblsLen)
      noisy.say "***", "n=", n,
        " leafs=", leafs.len,
        " proof=", rc.value.proof.ppNodeKeys(dbg),
        "\n\n   ",
        " base=", iv.minPt,
        "\n    ", iv.minPt.hexaryPath(rootKey,db).pp(dbg),
        "\n\n   ",
        " pfx=", pfxNbls,
        " nPfx=", nPfxNblsLen,
        "\n    ", pfxNbls.hexaryPath(rootKey,db).pp(dbg),
        "\n"

      check rx == typeof(rx).ok()
      return

    noisy.say "***", "n=", n,
      " leafs=", leafs.len,
      " proof=", rc.value.proof.len, "/", w.data.proof.len


proc test_NodeRangeLeftBoundary*(
    inLst: seq[UndumpAccounts];
    db: HexaryTreeDbRef|HexaryGetFn;         ## Database abstraction
    dbg = HexaryTreeDbRef(nil);              ## Debugging env
      ) =
  ## Verify left side boundary checks
  let
    rootKey = inLst[0].root.to(NodeKey)
    noisy = not dbg.isNil

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
    noisy.say "***", "n=", n, " accounts=", accounts.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
