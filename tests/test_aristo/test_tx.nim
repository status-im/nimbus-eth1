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
  ../../nimbus/db/core_db/backend/aristo_rocksdb,
  ../../nimbus/db/aristo/[
    aristo_check,
    aristo_debug,
    aristo_delete,
    aristo_desc,
    aristo_get,
    aristo_hike,
    aristo_init/persistent,
    aristo_nearby,
    aristo_part,
    aristo_part/part_debug,
    aristo_tx],
  ../replay/xcheck,
  ./test_helpers

type
  PrngDesc = object
    prng: uint32                       ## random state

  KnownHasherFailure* = seq[(string,(int,AristoError))]
    ## (<sample-name> & "#" <instance>, (<vertex-id>,<error-symbol>))

const
  testRootVid = VertexID(2)
    ## Need to reconfigure for the test, root ID 1 cannot be deleted as a trie

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
       ): Result[seq[(LeafTie,RootedVertexID)],(VertexID,AristoError)] =
  var lvp: seq[(LeafTie,RootedVertexID)]
  for lty in ltys:
    let hike = lty.hikeUp(db).valueOr:
      return err((error[0],error[1]))
    lvp.add (lty,(hike.root, hike.legs[^1].wp.vid))

  var lvp2 = lvp.sorted(
    cmp = proc(a,b: (LeafTie,RootedVertexID)): int = cmp(a[0],b[0]))
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
    db.finish(eradicate=true)
    db = AristoDbRef(nil)
  true

# --------------------------------

proc saveToBackend(
    tx: var AristoTxRef;
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

  block:
    let rc = db.txTop()
    xCheckRc rc.error == 0
    tx = rc.value

  # Verify context: nesting level must be 1 (i.e. one transaction)
  xCheck tx.level == 1

  block:
    let rc = db.checkBE()
    xCheckRc rc.error == (0,0)

  # Commit and save to backend
  block:
    let rc = tx.commit()
    xCheckRc rc.error == 0

  block:
    let rc = db.txTop()
    xCheckErr rc.value.level < 0 # force error

  block:
    let rc = db.schedStow()
    xCheckRc rc.error == 0

  block:
    let rc = db.checkBE()
    xCheckRc rc.error == (0,0):
      noisy.say "***", "saveToBackend (8)", " debugID=", debugID

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
      db.finish(eradicate=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      if 0 < rdbPath.len:
        let (dbOpts, cfOpts) = DbOptions.init().toRocksDb()
        let rc = AristoDbRef.init(RdbBackendRef, rdbPath, dbOpts, cfOpts, [])
        xCheckRc rc.error == 0
        rc.value()[0]
      else:
        AristoDbRef.init(MemBackendRef)

    # Start transaction (double frame for testing)
    xCheck db.txTop.isErr
    var tx = db.txBegin().value.to(AristoDbRef).txBegin().value
    xCheck tx.isTop()
    xCheck tx.level == 2

    # Reset database so that the next round has a clean setup
    defer: db.innerCleanUp

    # Merge leaf data into main trie
    let kvpLeafs = block:
      var lst = w.kvpLst.mapRootVid testRootVid
      # The list might be reduced for isolation of particular properties,
      # e.g. lst.setLen(min(5,lst.len))
      lst
    for i,leaf in kvpLeafs:
      let rc = db.mergeGenericData leaf
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
        let saveBeOk = tx.saveToBackend(relax=relax, noisy=noisy, runID)
        xCheck saveBeOk:
          noisy.say "***", "del1by1(2)",
            " u=", u,
            " n=", n, "/", list.len,
            "\n    db\n    ", db.pp(backendOk=true),
            ""

      # Delete leaf
      block:
        let rc = db.deleteGenericData(leaf.root, @(leaf.path))
        xCheckRc rc.error == 0

      # Update list of remaininf leafs
      leafsLeft.excl leaf

      let deletedVtx = tx.db.getVtx lid
      xCheck deletedVtx.isValid == false:
        noisy.say "***", "del1by1(8)"

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
      noisy.say "***", "del1by1(9)",
        " n=", n, "/", list.len,
        " nLeafs=", kvpLeafs.len

  true


proc testTxMergeAndDeleteSubTree*(
    noisy: bool;
    list: openArray[ProofTrieData];
    rdbPath: string;                          # Rocks DB storage directory
       ): bool =
  var
    prng = PrngDesc.init 42
    db = AristoDbRef(nil)
  defer:
    if not db.isNil:
      db.finish(eradicate=true)

  for n,w in list:
    # Start with brand new persistent database.
    db = block:
      if 0 < rdbPath.len:
        let (dbOpts, cfOpts) = DbOptions.init().toRocksDb()
        let rc = AristoDbRef.init(RdbBackendRef, rdbPath, dbOpts, cfOpts, [])
        xCheckRc rc.error == 0
        rc.value()[0]
      else:
        AristoDbRef.init(MemBackendRef)

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
      let rc = db.mergeGenericData leaf
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
      let saveBeOk = tx.saveToBackend(relax=false, noisy=noisy, 1+list.len*n)
      xCheck saveBeOk:
        noisy.say "***", "del(1)",
          " n=", n, "/", list.len,
          "\n    db\n    ", db.pp(backendOk=true),
          ""
    # Delete sub-tree
    block:
      let rc = db.deleteGenericTree testRootVid
      xCheckRc rc.error == 0:
        noisy.say "***", "del(2)",
          " n=", n, "/", list.len,
          "\n    db\n    ", db.pp(backendOk=true),
          ""
    block:
      let saveBeOk = tx.saveToBackend(relax=false, noisy=noisy, 2+list.len*n)
      xCheck saveBeOk:
        noisy.say "***", "del(3)",
          " n=", n, "/", list.len,
          "\n    db\n    ", db.pp(backendOk=true),
          ""
    when true and false:
      noisy.say "***", "del(9) n=", n, "/", list.len, " nLeafs=", kvpLeafs.len

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
