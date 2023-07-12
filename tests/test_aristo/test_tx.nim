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

## Aristo (aka Patricia) DB records merge test

import
  std/[algorithm, bitops, sequtils, sets, tables],
  eth/common,
  stew/results,
  unittest2,
  ../../nimbus/db/aristo,
  ../../nimbus/db/aristo/[aristo_check, aristo_desc, aristo_get, aristo_merge],
  ./test_helpers

type
  PrngDesc = object
    prng: uint32                       ## random state

  KnownHasherFailure* = seq[(string,(int,AristoError))]
    ## (<sample-name> & "#" <instance>, (<vertex-id>,<error-symbol>))

const
  WalkStopRc =
    Result[LeafTie,(VertexID,AristoError)].err((VertexID(0),NearbyBeyondRange))

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc rand[W: SomeInteger|VertexID](ap: var PrngDesc; T: type W): T =
  var a: array[sizeof T,byte]
  for n in 0 ..< sizeof T:
    a[n] = ap.prng.posixPrngRand().byte
  when sizeof(T) == 1:
    let w = uint8.fromBytesBE(a).T
  when sizeof(T) == 2:
    let w = uint16.fromBytesBE(a).T
  when sizeof(T) == 4:
    let w = uint32.fromBytesBE(a).T
  else:
    let w = uint64.fromBytesBE(a).T
  when T is SomeUnsignedInt:
    # That way, `fromBytesBE()` can be applied to `uint`
    result = w
  else:
    # That way the result is independent of endianness
    (addr result).copyMem(unsafeAddr w, sizeof w)

proc init(T: type PrngDesc; seed: int): PrngDesc =
  result.prng = (seed and 0x7fffffff).uint32

proc rand(td: var PrngDesc; top: int): int =
  if 0 < top:
    let mask = (1 shl (8 * sizeof(int) - top.countLeadingZeroBits)) - 1
    for _ in 0 ..< 100:
      let w = mask and td.rand(typeof(result))
      if w < top:
        return w
    raiseAssert "Not here (!)"

# -----------------------

proc randomisedLeafs(
    tx: AristoTxRef;
    td: var PrngDesc;
       ): seq[(LeafTie,VertexID)] =
  result = tx.db.top.lTab.pairs.toSeq.filterIt(it[1].isvalid).sorted(
    cmp = proc(a,b: (LeafTie,VertexID)): int = cmp(a[0], b[0]))
  if 2 < result.len:
    for n in 0 ..< result.len-1:
      let r = n + td.rand(result.len - n)
      result[n].swap result[r]


proc innerCleanUp(
  tdb: AristoTxRef;                           # Level zero tx
  tx: AristoTxRef;                            # Active transaction (if any)
    ) =
  ## Defer action
  if not tx.isNil:
    let rc = tx.collapse(commit=false)
    if rc.isErr:
      check rc.error == (0,0)
    else:
      check rc.value == tdb
  if not tdb.isNil:
    let rc = tdb.done(flush=true)
    if rc.isErr:
      check rc.error == 0


proc saveToBackend(
    tx: var AristoTxRef;
    relax: bool;
    noisy: bool;
    debugID: int;
      ): bool =
  # Verify context (nesting level must be 2)
  block:
    let levels = tx.level
    if levels != (2,2):
      check levels == (2,2)
      return
  block:
    let rc = tx.db.checkCache(relax=true)
    if rc.isErr:
      check rc.error == (0,0)
      return

  # Implicitely force hashify by committing the current layer
  block:
    let rc = tx.commit(hashify=true)
    if rc.isErr:
      check rc.error == (0,0)
      return
    tx = rc.value
    let levels = tx.level
    if levels != (1,1):
      check levels == (1,1)
      return
  block:
    let rc = tx.db.checkBE(relax=true)
    if rc.isErr:
      check rc.error == (0,0)
      return

  # Save to backend
  block:
    let rc = tx.commit()
    if rc.isErr:
      check rc.error == (0,0)
      return
    tx = rc.value
    let levels = tx.level
    if levels != (0,0):
      check levels == (1,1)
      return
  block:
    let rc = tx.db.checkBE(relax=relax)
    if rc.isErr:
      check rc.error == (0,0)
      return

  # Update layers to original level
  tx = tx.begin.value.begin.value

  true

proc saveToBackendWithOops(
    tx: var AristoTxRef;
    noisy: bool;
    debugID: int;
    oops: (int,AristoError);
      ): bool =
  block:
    let levels = tx.level
    if levels != (2,2):
      check levels == (2,2)
      return

  # Implicitely force hashify by committing the current layer
  block:
    let rc = tx.commit(hashify=true)
    # Handle known errors
    if rc.isOK:
      if oops != (0,0):
        check oops == (0,0)
        return
    else:
      if rc.error != oops:
        check rc.error == oops
        return
    tx = rc.value
    let levels = tx.level
    if levels != (1,1):
      check levels == (1,1)
      return

  # Save to backend
  block:
    let rc = tx.commit()
    if rc.isErr:
      check rc.error == (0,0)
      return
    tx = rc.value
    let levels = tx.level
    if levels != (0,0):
      check levels == (1,1)
      return

  # Update layers to original level
  tx = tx.begin.value.begin.value

  true


proc fwdWalkVerify(
    tx: AristoTxRef;
    root: VertexID;
    leftOver: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): bool =
  let
    nLeafs = leftOver.len
  var
    leftOver = leftOver
    last = LeafTie()
    n = 0
  for (key,_) in tx.right low(LeafTie,root):
    if key notin leftOver:
      noisy.say "*** fwdWalkVerify", " id=", n + (nLeafs + 1) * debugID
      check key in leftOver
      return
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = low(LeafTie,root)
  elif last != high(LeafTie,root):
    last = last + 1
  let rc = last.right tx
  if rc.isOk or rc.error[1] != NearbyBeyondRange:
    check rc == WalkStopRc
    return

  if n != nLeafs:
    check n == nLeafs
    return

  true

proc revWalkVerify(
    tx: AristoTxRef;
    root: VertexID;
    leftOver: HashSet[LeafTie];
    noisy: bool;
    debugID: int;
      ): bool =
  let
    nLeafs = leftOver.len
  var
    leftOver = leftOver
    last = LeafTie()
    n = 0
  for (key,_) in tx.left high(LeafTie,root):
    if key notin leftOver:
      noisy.say "*** revWalkVerify", " id=", n + (nLeafs + 1) * debugID
      check key in leftOver
      return
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = high(LeafTie,root)
  elif last != low(LeafTie,root):
    last = last - 1
  let rc = last.left tx
  if rc.isOk or rc.error[1] != NearbyBeyondRange:
    check rc == WalkStopRc
    return

  if n != nLeafs:
    check n == nLeafs
    return

  true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testTxMergeAndDelete*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var
    prng = PrngDesc.init 42
    db = AristoDbRef()
    fwdRevVfyToggle = true
  defer:
    db.finish(flush=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      let rc = AristoDbRef.init(BackendRocksDB,rdbPath)
      if rc.isErr:
        check rc.error == 0
        return
      rc.value

    # Convert to transaction layer
    let tdb = db.to(AristoTxRef)
    check tdb.isBase
    check not tdb.isTop

    # Start transaction (double frame for testing)
    var tx = tdb.begin.value.begin.value
    check not tx.isBase
    check tx.isTop

    # Reset database so that the next round has a clean setup
    defer:
      tdb.innerCleanUp tx

    # Merge leaf data into main trie (w/vertex ID 1)
    let kvpLeafs = w.kvpLst.mapRootVid VertexID(1)
    for leaf in kvpLeafs:
      let rc = tx.put leaf
      if rc.isErr:
        check rc.error == 0
        return

    # List of all leaf entries that should be on the database
    var leafsLeft = kvpLeafs.mapIt(it.leafTie).toHashSet

    # Provide a (reproducible) peudo-random copy of the leafs list
    let leafVidPairs = tx.randomisedLeafs prng
    if leafVidPairs.len != leafsLeft.len:
      check leafVidPairs.len == leafsLeft.len
      return

    # Trigger subsequent saving tasks in loop below
    let (saveMod, saveRest, relax) = block:
      if leafVidPairs.len < 17:    (7, 3, false)
      elif leafVidPairs.len < 31: (11, 7, false)
      else:   (leafVidPairs.len div 5, 11, true)

    # === Loop over leafs ===
    for u,lvp in leafVidPairs:
      let
        runID = n + list.len * u
        tailWalkVerify = 7 # + 999
        doSaveBeOk = ((u mod saveMod) == saveRest)
        (leaf, lid) = lvp

      if doSaveBeOk:
        if not tx.saveToBackend(relax=relax, noisy=noisy, runID):
          return

      # Delete leaf
      let rc = tx.del leaf
      if rc.isErr:
        check rc.error == (0,0)
        return

      # Update list of remaininf leafs
      leafsLeft.excl leaf

      let deletedVtx = tx.db.getVtx lid
      if deletedVtx.isValid:
        check deletedVtx.isValid == false
        return

      # Walking the database is too slow for large tables. So the hope is that
      # potential errors will not go away and rather pop up later, as well.
      if leafsLeft.len <= tailWalkVerify:
        if u < leafVidPairs.len-1:
          if fwdRevVfyToggle:
            fwdRevVfyToggle = false
            if not tx.fwdWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return
          else:
            fwdRevVfyToggle = true
            if not tx.revWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return

    when true and false:
      noisy.say "***", "del(9) n=", n, "/", list.len, " nLeafs=", kvpLeafs.len

  true


proc testTxMergeProofAndKvpList*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                         # Rocks DB storage directory
    resetDb = false;
    idPfx = "";
    oops: KnownHasherFailure = @[];
      ): bool =
  let
    oopsTab = oops.toTable
  var
    adb = AristoDbRef()
    tdb, tx: AristoTxRef
    rootKey: HashKey
    count = 0
  defer:
    adb.finish(flush=true)

  for n,w in list:

    # Start new database upon request
    if resetDb or w.root != rootKey or w.proof.len == 0:
      tdb.innerCleanUp tx
      adb = block:
        let rc = AristoDbRef.init(BackendRocksDB,rdbPath)
        if rc.isErr:
          check rc.error == 0
          return
        rc.value

      # Convert to transaction layer
      tdb = adb.to(AristoTxRef)
      check tdb.isBase
      check not tdb.isTop

      # Start transaction (double frame for testing)
      tx = tdb.begin.value.begin.value
      check not tx.isBase
      check tx.isTop

      # Update root
      rootKey = w.root
      count = 0
    count.inc

    let
      testId = idPfx & "#" & $w.id & "." & $n
      runID = n
      lstLen = list.len
      sTabLen = tx.db.top.sTab.len
      lTabLen = tx.db.top.lTab.len
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie

    var
      proved: tuple[merged: int, dups: int, error: AristoError]
    if 0 < w.proof.len:
      let rc = tx.db.merge(rootKey, VertexID(1))
      if rc.isErr:
        check rc.error == 0
        return

      proved = tx.db.merge(w.proof, rc.value) # , noisy)

      check proved.error in {AristoError(0),MergeHashKeyCachedAlready}
      check w.proof.len == proved.merged + proved.dups
      check tx.db.top.lTab.len == lTabLen
      check tx.db.top.sTab.len <= proved.merged + sTabLen
      check proved.merged < tx.db.top.pAmk.len

    let
      merged = tx.db.merge leafs

    check tx.db.top.lTab.len == lTabLen + merged.merged
    check merged.merged + merged.dups == leafs.len

    block:
      if merged.error notin {AristoError(0), MergeLeafPathCachedAlready}:
        check merged.error in {AristoError(0), MergeLeafPathCachedAlready}
        return

    block:
      let oops = oopsTab.getOrDefault(testId,(0,AristoError(0)))
      if not tx.saveToBackendWithOops(noisy, runID, oops):
        return

    when true and false:
      noisy.say "***", "proofs(6) <", n, "/", lstLen-1, ">",
        " groups=", count, " proved=", proved.pp, " merged=", merged.pp
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
