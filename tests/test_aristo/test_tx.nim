# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Aristo (aka Patricia) DB records transaction based merge test

import
  std/[algorithm, bitops, sequtils, sets, tables],
  eth/common,
  results,
  unittest2,
  stew/endians2,
  ../../nimbus/db/opts,
  ../../nimbus/db/aristo/[
    aristo_check,
    aristo_debug,
    aristo_delete,
    aristo_desc,
    aristo_get,
    aristo_hike,
    aristo_init/persistent,
    aristo_layers,
    aristo_merge,
    aristo_nearby,
    aristo_tx],
  ../replay/xcheck,
  ./test_helpers

type
  PrngDesc = object
    prng: uint32                       ## random state

  KnownHasherFailure* = seq[(string,(int,AristoError))]
    ## (<sample-name> & "#" <instance>, (<vertex-id>,<error-symbol>))

const
  MaxFilterBulk = 150_000
    ## Policy settig for `pack()`

let
  TxQidLyo = LyoSamples[0][0].to(QidLayoutRef)
    ## Cascaded filter slots layout for testing

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
    db: AristoDbRef;
    ltys: HashSet[LeafTie];
    td: var PrngDesc;
       ): Result[seq[(LeafTie,VertexID)],(VertexID,AristoError)] =
  var lvp: seq[(LeafTie,VertexID)]
  for lty in ltys:
    let hike = lty.hikeUp(db).valueOr:
      return err((error[0],error[1]))
    lvp.add (lty,hike.legs[^1].wp.vid)

  var lvp2 = lvp.sorted(
    cmp = proc(a,b: (LeafTie,VertexID)): int = cmp(a[0],b[0]))
  if 2 < lvp2.len:
    for n in 0 ..< lvp2.len-1:
      let r = n + td.rand(lvp2.len - n)
      lvp2[n].swap lvp2[r]
  ok lvp2

proc innerCleanUp(db: var AristoDbRef): bool {.discardable.}  =
  ## Defer action
  if not db.isNil:
    let rx = db.txTop()
    if rx.isOk:
      let rc = rx.value.collapse(commit=false)
      xCheckRc rc.error == 0
    db.finish(flush=true)
    db = AristoDbRef(nil)

proc schedStow(
    db: AristoDbRef;                  # Database
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## Scheduled storage
  let
    layersMeter = db.nLayersVtx() + db.nLayersKey()
    filterMeter = if db.roFilter.isNil: 0
                  else: db.roFilter.sTab.len + db.roFilter.kMap.len
    persistent = MaxFilterBulk < max(layersMeter, filterMeter)
  if persistent:
    db.persist(chunkedMpt=chunkedMpt)
  else:
    db.stow(chunkedMpt=chunkedMpt)

proc saveToBackend(
    tx: var AristoTxRef;
    chunkedMpt: bool;
    relax: bool;
    noisy: bool;
    debugID: int;
      ): bool =
  var db = tx.to(AristoDbRef)

  # Verify context: nesting level must be 2 (i.e. two transactions)
  xCheck tx.level == 2

  block:
    let rc = db.checkTop()
    xCheckRc rc.error == (0,0)

  # Commit and hashify the current layer
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.dirty.len == 0

  block:
    let rc = db.txTop()
    xCheckRc rc.error == 0
    tx = rc.value

  # Verify context: nesting level must be 1 (i.e. one transaction)
  xCheck tx.level == 1

  block:
    let rc = db.checkBE(relax=true)
    xCheckRc rc.error == (0,0)

  # Commit and save to backend
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.dirty.len == 0

  block:
    let rc = db.txTop()
    xCheckErr rc.value.level < 0 # force error

  block:
    let rc = db.schedStow(chunkedMpt=chunkedMpt)
    xCheckRc rc.error == 0

  block:
    let rc = db.checkBE(relax=relax)
    xCheckRc rc.error == (0,0):
      noisy.say "***", "saveToBackend (8)", " debugID=", debugID

  # Update layers to original level
  tx = db.txBegin().value.to(AristoDbRef).txBegin().value

  true

proc saveToBackendWithOops(
    tx: var AristoTxRef;
    chunkedMpt: bool;
    noisy: bool;
    debugID: int;
    oops: (int,AristoError);
      ): bool =
  var db = tx.to(AristoDbRef)

  # Verify context: nesting level must be 2 (i.e. two transactions)
  xCheck tx.level == 2

  # Commit and hashify the current layer
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.dirty.len == 0

  block:
    let rc = db.txTop()
    xCheckRc rc.error == 0
    tx = rc.value

  # Verify context: nesting level must be 1 (i.e. one transaction)
  xCheck tx.level == 1

  # Commit and save to backend
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  # Make sure MPT hashes are OK
  xCheck db.dirty.len == 0

  block:
    let rc = db.txTop()
    xCheckErr rc.value.level < 0 # force error

  block:
    let rc = db.schedStow(chunkedMpt=chunkedMpt)
    xCheckRc rc.error == 0

  # Update layers to original level
  tx = db.txBegin().value.to(AristoDbRef).txBegin().value

  true


proc fwdWalkVerify(
    db: AristoDbRef;
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
  for (key,_) in db.rightPairs low(LeafTie,root):
    xCheck key in leftOver:
      noisy.say "*** fwdWalkVerify", "id=", n + (nLeafs + 1) * debugID
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = low(LeafTie,root)
  elif last != high(LeafTie,root):
    last = last.next
  let rc = last.right db
  xCheck rc.isErr
  xCheck rc.error[1] == NearbyBeyondRange
  xCheck n == nLeafs

  true

proc revWalkVerify(
    db: AristoDbRef;
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
  for (key,_) in db.leftPairs high(LeafTie,root):
    xCheck key in leftOver:
      noisy.say "*** revWalkVerify", " id=", n + (nLeafs + 1) * debugID
    leftOver.excl key
    last = key
    n.inc

  # Verify stop condition
  if last.root == VertexID(0):
    last = high(LeafTie,root)
  elif last != low(LeafTie,root):
    last = last.prev
  let rc = last.left db
  xCheck rc.isErr
  xCheck rc.error[1] == NearbyBeyondRange
  xCheck n == nLeafs

  true

proc mergeRlpData*(
    db: AristoDbRef;                   # Database, top layer
    path: PathID;                      # Path into database
    rlpData: openArray[byte];          # RLP encoded payload data
      ): Result[void,AristoError] =
  block body:
    discard db.mergeLeaf(
      LeafTiePayload(
        leafTie: LeafTie(
          root:    VertexID(1),
          path:    path.normal),
        payload: PayloadRef(
          pType:   RlpData,
          rlpBlob: @rlpData))).valueOr:
      if error in {MergeLeafPathCachedAlready,MergeLeafPathOnBackendAlready}:
        break body
      return err(error)
  ok()

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc testTxMergeAndDeleteOneByOne*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var
    prng = PrngDesc.init 42
    db = AristoDbRef(nil)
    fwdRevVfyToggle = true
  defer:
    if not db.isNil:
      db.finish(flush=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      if 0 < rdbPath.len:
        let rc = AristoDbRef.init(
          RdbBackendRef, rdbPath, qidLayout=TxQidLyo, DbOptions.init())
        xCheckRc rc.error == 0
        rc.value
      else:
        AristoDbRef.init(MemBackendRef, qidLayout=TxQidLyo)

    # Start transaction (double frame for testing)
    xCheck db.txTop.isErr
    var tx = db.txBegin().value.to(AristoDbRef).txBegin().value
    xCheck tx.isTop()
    xCheck tx.level == 2

    # Reset database so that the next round has a clean setup
    defer: db.innerCleanUp

    # Merge leaf data into main trie (w/vertex ID 1)
    let kvpLeafs = block:
      var lst = w.kvpLst.mapRootVid VertexID(1)
      # The list might be reduced for isolation of particular properties,
      # e.g. lst.setLen(min(5,lst.len))
      lst
    for i,leaf in kvpLeafs:
      let rc = db.mergeLeaf leaf
      xCheckRc rc.error == 0

    # List of all leaf entries that should be on the database
    var leafsLeft = kvpLeafs.mapIt(it.leafTie).toHashSet

    # Provide a (reproducible) peudo-random copy of the leafs list
    let leafVidPairs = block:
      let rc = db.randomisedLeafs(leafsLeft, prng)
      xCheckRc rc.error == (0,0)
      rc.value

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
        let saveBeOk = tx.saveToBackend(
          chunkedMpt=false, relax=relax, noisy=noisy, runID)
        xCheck saveBeOk:
          noisy.say "***", "del(2)",
            " u=", u,
            " n=", n, "/", list.len,
            "\n    leaf=", leaf.pp(db),
            "\n    db\n    ", db.pp(backendOk=true),
            ""

      # Delete leaf
      block:
        let rc = db.delete(leaf, VOID_PATH_ID)
        xCheckRc rc.error == (0,0)

      # Update list of remaininf leafs
      leafsLeft.excl leaf

      let deletedVtx = tx.db.getVtx lid
      xCheck deletedVtx.isValid == false

      # Walking the database is too slow for large tables. So the hope is that
      # potential errors will not go away and rather pop up later, as well.
      if leafsLeft.len <= tailWalkVerify:
        if u < leafVidPairs.len-1:
          if fwdRevVfyToggle:
            fwdRevVfyToggle = false
            if not db.fwdWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return
          else:
            fwdRevVfyToggle = true
            if not db.revWalkVerify(leaf.root, leafsLeft, noisy, runID):
              return

    when true and false:
      noisy.say "***", "del(9) n=", n, "/", list.len, " nLeafs=", kvpLeafs.len

  true


proc testTxMergeAndDeleteSubTree*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  const
    # Need to reconfigure for the test, root ID 1 cannot be deleted as a trie
    testRootVid = VertexID(2)
  var
    prng = PrngDesc.init 42
    db = AristoDbRef(nil)
  defer:
    if not db.isNil:
      db.finish(flush=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      if 0 < rdbPath.len:
        let rc = AristoDbRef.init(
          RdbBackendRef, rdbPath, qidLayout=TxQidLyo, DbOptions.init())
        xCheckRc rc.error == 0
        rc.value
      else:
        AristoDbRef.init(MemBackendRef, qidLayout=TxQidLyo)

    if testRootVid != VertexID(1):
      # Add a dummy entry so the journal logic can be triggered
      discard db.merge(VertexID(1), @[n.byte], @[42.byte], VOID_PATH_ID)

    # Start transaction (double frame for testing)
    xCheck db.txTop.isErr
    var tx = db.txBegin().value.to(AristoDbRef).txBegin().value
    xCheck tx.isTop()
    xCheck tx.level == 2

    # Reset database so that the next round has a clean setup
    defer: db.innerCleanUp

    # Merge leaf data into main trie (w/vertex ID 2)
    let kvpLeafs = block:
      var lst = w.kvpLst.mapRootVid testRootVid
      # The list might be reduced for isolation of particular properties,
      # e.g. lst.setLen(min(5,lst.len))
      lst
    for i,leaf in kvpLeafs:
      let rc = db.mergeLeaf leaf
      xCheckRc rc.error == 0

    # List of all leaf entries that should be on the database
    var leafsLeft = kvpLeafs.mapIt(it.leafTie).toHashSet

    # Provide a (reproducible) peudo-random copy of the leafs list
    let leafVidPairs = block:
      let rc = db.randomisedLeafs(leafsLeft, prng)
      xCheckRc rc.error == (0,0)
      rc.value
    discard leafVidPairs

    # === delete sub-tree ===
    block:
      let saveBeOk = tx.saveToBackend(
        chunkedMpt=false, relax=false, noisy=noisy, 1 + list.len * n)
      xCheck saveBeOk:
        noisy.say "***", "del(1)",
          " n=", n, "/", list.len,
          "\n    db\n    ", db.pp(backendOk=true),
          ""
    # Delete sub-tree
    block:
      let rc = db.delTree(testRootVid, VOID_PATH_ID)
      xCheckRc rc.error == (0,0):
        noisy.say "***", "del(2)",
          " n=", n, "/", list.len,
          "\n    db\n    ", db.pp(backendOk=true),
          ""

    if testRootVid != VertexID(1):
      # Update dummy entry so the journal logic can be triggered
      discard db.merge(VertexID(1), @[n.byte], @[43.byte], VOID_PATH_ID)

    block:
      let saveBeOk = tx.saveToBackend(
        chunkedMpt=false, relax=false, noisy=noisy, 2 + list.len * n)
      xCheck saveBeOk:
        noisy.say "***", "del(3)",
          " n=", n, "/", list.len,
          "\n    db\n    ", db.pp(backendOk=true),
          ""
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
    db = AristoDbRef(nil)
    tx = AristoTxRef(nil)
    rootKey: Hash256
    count = 0
  defer:
    if not db.isNil:
      db.finish(flush=true)

  for n,w in list:

    # Start new database upon request
    if resetDb or w.root != rootKey or w.proof.len == 0:
      db.innerCleanUp
      db = block:
        # New DB with disabled filter slots management
        if 0 < rdbPath.len:
          let rc = AristoDbRef.init(
            RdbBackendRef, rdbPath, QidLayoutRef(nil), DbOptions.init())
          xCheckRc rc.error == 0
          rc.value
        else:
          AristoDbRef.init(MemBackendRef, QidLayoutRef(nil))

      # Start transaction (double frame for testing)
      tx = db.txBegin().value.to(AristoDbRef).txBegin().value
      xCheck tx.isTop()

      # Update root
      rootKey = w.root
      count = 0
    count.inc

    let
      testId = idPfx & "#" & $w.id & "." & $n
      runID = n
      sTabLen = db.nLayersVtx()
      leafs = w.kvpLst.mapRootVid VertexID(1) # merge into main trie

    if 0 < w.proof.len:
      let root = block:
        let rc = db.merge(rootKey, VertexID(1))
        xCheckRc rc.error == 0
        rc.value

      let nMerged = block:
        let rc = db.merge(w.proof, root)
        xCheckRc rc.error == 0
        rc.value

      xCheck w.proof.len == nMerged
      xCheck db.nLayersVtx() <= nMerged + sTabLen

    let merged = db.mergeList leafs
    xCheck merged.error in {AristoError(0), MergeLeafPathCachedAlready}
    xCheck merged.merged + merged.dups == leafs.len

    block:
      let oops = oopsTab.getOrDefault(testId,(0,AristoError(0)))
      if not tx.saveToBackendWithOops(
          chunkedMpt=true, noisy=noisy, debugID=runID, oops):
        return

    when true and false:
      noisy.say "***", "testTxMergeProofAndKvpList (1)",
        " <", n, "/", list.len-1, ">",
        " runID=", runID,
        " groups=", count, " merged=", merged

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
