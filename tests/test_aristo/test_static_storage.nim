# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/os,
  unittest2,
  results,
  tempfile,
  eth/common/hashes,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[
    aristo_blobify,
    aristo_delete,
    aristo_desc,
    aristo_fetch,
    aristo_get,
    aristo_tx_frame,
    aristo_vid,
    aristo_init/init_common,
    aristo_init/memory_only,
    aristo_init/rocks_db,
    aristo_merge,
  ],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

proc path(bytes: varargs[byte]): Hash32 =
  for i, b in bytes:
    result.data[i] = b

proc account(i: uint64): AristoAccount =
  AristoAccount(nonce: i, balance: i.u256, codeHash: EMPTY_CODE_HASH)

const
  accA = path(0xa0, 0x01)
  accB = path(0xb0, 0x20)
  slot1 = path(0x10, 0x01)
  slot2 = path(0x10, 0x02)
  slot3 = path(0x20, 0x03)
  slot4 = path(0x10, 0x01, 0x10)
  slot5 = path(0x40, 0x05)
  slotMissing = path(0x30, 0x04)

proc persist(db: AristoDbRef, tx: AristoTxRef, blockNumber: uint64) =
  tx.checkpoint(blockNumber, skipSnapshot = true)
  let batch = db.putBegFn()[]
  db.persist(batch, tx)
  doAssert db.putEndFn(batch).isOk()

proc slotBothWays(db: AristoDbRef, accPath, stoPath: Hash32): UInt256 =
  db.stoStatic = true
  let viaProbe = db.txRef.fetchSlot(accPath, stoPath).expect("probe")
  db.stoStatic = false
  let viaWalk = db.txRef.fetchSlot(accPath, stoPath).expect("walk")
  db.stoStatic = true
  doAssert viaWalk == viaProbe, "static probe and walk disagree"
  viaProbe

proc probeLevelOf(db: AristoDbRef, accPath: Hash32): int =
  let startLevel = db.txRef.fetchStorageInfo(accPath).expect("account")[1]
  if startLevel.isSome: startLevel[] else: -1

proc stoRoot(db: AristoDbRef, accPath: Hash32): VertexID =
  db.txRef.fetchStorageID(accPath).expect("storage")

proc probeVertexOf(db: AristoDbRef, accPath, stoPath: Hash32): VertexRef =
  let
    root = db.stoRoot(accPath)
    level = db.probeLevelOf(accPath)
    nib = NibblesBuf.fromBytes(stoPath.data)
    rc = db.txRef.getVtxRc((root, if level == 0: root else: nib.staticVid(level)))
  if rc.isOk: rc.value[0] else: VertexRef(nil)

suite "Aristo static storage vids":
  setup:
    let db = AristoDbRef.init()
    doAssert db.stoStatic

  test "single slot trie: root leaf, hint 1":
    let tx = db.txFrameBegin(db.txRef)
    check:
      tx.mergeAccount(accA, account(1)).isOk()
      tx.mergeSlot(accA, slot1, 11.u256).isOk()
    db.persist(tx, 1)
    check:
      db.probeLevelOf(accA) == 0
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slotMissing) == 0.u256

  test "children sit at static vids relative to the storage root":
    let tx = db.txFrameBegin(db.txRef)
    check:
      tx.mergeAccount(accA, account(1)).isOk()
      tx.mergeSlot(accA, slot1, 11.u256).isOk()
      tx.mergeSlot(accA, slot3, 33.u256).isOk()
    db.persist(tx, 1)
    let root = db.stoRoot(accA)
    check:
      db.probeLevelOf(accA) == 0
      db.txRef.getVtxRc((root, NibblesBuf.fromBytes(slot1.data).staticVid(1))).isOk()
      db.txRef.getVtxRc((root, NibblesBuf.fromBytes(slot3.data).staticVid(1))).isOk()
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slot3) == 33.u256

  test "a deeper placement starts the probe at its branch, not inside an extension":
    let tx = db.txFrameBegin(db.txRef)
    check:
      tx.mergeAccount(accA, account(1)).isOk()
      tx.mergeSlot(accA, slot1, 11.u256).isOk()
      tx.mergeSlot(accA, slot2, 22.u256).isOk()
    db.persist(tx, 1)
    check:
      db.probeLevelOf(accA) == 0
      db.probeVertexOf(accA, slot2).vType == ExtBranch
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slot2) == 22.u256

  test "split deepens the hint, collapse keeps the probe correct":
    let tx0 = db.txFrameBegin(db.txRef)
    check:
      tx0.mergeAccount(accA, account(1)).isOk()
      tx0.mergeSlot(accA, slot1, 11.u256).isOk()
      tx0.mergeSlot(accA, slot3, 33.u256).isOk()
      tx0.mergeSlot(accA, slot2, 22.u256).isOk()
    db.persist(tx0, 1)
    check:
      db.probeLevelOf(accA) == 1
      db.probeVertexOf(accA, slot2).vType == ExtBranch
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slot2) == 22.u256
      db.slotBothWays(accA, slot3) == 33.u256

    let tx1 = db.txFrameBegin(db.txRef)
    check tx1.deleteSlot(accA, slot2).isOk()
    db.persist(tx1, 2)
    check:
      db.probeLevelOf(accA) == 1
      db.probeVertexOf(accA, slot1).vType == StoLeaf
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slot2) == 0.u256
      db.slotBothWays(accA, slot3) == 33.u256

  test "a shallow placement lowers the hint, deep leaves stay reachable":
    let tx0 = db.txFrameBegin(db.txRef)
    check:
      tx0.mergeAccount(accA, account(1)).isOk()
      tx0.mergeSlot(accA, slot1, 11.u256).isOk()
      tx0.mergeSlot(accA, slot3, 33.u256).isOk()
      tx0.mergeSlot(accA, slot2, 22.u256).isOk()
      tx0.mergeSlot(accA, slot4, 44.u256).isOk()
    db.persist(tx0, 1)
    check:
      db.probeLevelOf(accA) == 4
      db.probeVertexOf(accA, slot4).vType == Branch

    let tx1 = db.txFrameBegin(db.txRef)
    check tx1.mergeSlot(accA, slot5, 55.u256).isOk()
    db.persist(tx1, 2)
    check:
      db.probeLevelOf(accA) == 1
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slot2) == 22.u256
      db.slotBothWays(accA, slot3) == 33.u256
      db.slotBothWays(accA, slot4) == 44.u256
      db.slotBothWays(accA, slot5) == 55.u256
      db.slotBothWays(accA, slotMissing) == 0.u256

    let tx2 = db.txFrameBegin(db.txRef)
    check tx2.mergeSlot(accA, slot1, 111.u256).isOk()
    db.persist(tx2, 3)
    check:
      db.probeLevelOf(accA) == 1
      db.slotBothWays(accA, slot1) == 111.u256

  test "a collapse at the start level keeps the hint, one above it lowers it":
    let tx0 = db.txFrameBegin(db.txRef)
    check:
      tx0.mergeAccount(accA, account(1)).isOk()
      tx0.mergeSlot(accA, slot1, 11.u256).isOk()
      tx0.mergeSlot(accA, slot3, 33.u256).isOk()
      tx0.mergeSlot(accA, slot2, 22.u256).isOk()
      tx0.mergeSlot(accA, slot4, 44.u256).isOk()
    db.persist(tx0, 1)
    check db.probeLevelOf(accA) == 4

    let tx1 = db.txFrameBegin(db.txRef)
    check tx1.deleteSlot(accA, slot4).isOk()
    db.persist(tx1, 2)
    check:
      db.probeLevelOf(accA) == 4
      db.probeVertexOf(accA, slot1).vType == StoLeaf
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accA, slot4) == 0.u256

    let tx2 = db.txFrameBegin(db.txRef)
    check tx2.deleteSlot(accA, slot1).isOk()
    db.persist(tx2, 3)
    check:
      db.probeLevelOf(accA) == 1
      db.probeVertexOf(accA, slot2).vType == StoLeaf
      db.slotBothWays(accA, slot1) == 0.u256
      db.slotBothWays(accA, slot2) == 22.u256
      db.slotBothWays(accA, slot3) == 33.u256

  test "a branch-sibling collapse leaves the probe level alone":
    # sB and sC share three nibbles, sA diverges at the first, so deleting sA
    # collapses the root branch onto a branch rather than onto a leaf
    let
      sA = path(0x10, 0x01)
      sB = path(0x20, 0x01)
      sC = path(0x20, 0x02)
    let tx = db.txFrameBegin(db.txRef)
    check:
      tx.mergeAccount(accA, account(1)).isOk()
      tx.mergeSlot(accA, sA, 11.u256).isOk()
      tx.mergeSlot(accA, sB, 22.u256).isOk()
      tx.mergeSlot(accA, sC, 33.u256).isOk()
    db.persist(tx, 1)
    let root = db.stoRoot(accA)

    proc leafLevel(sp: Hash32): int =
      let nib = NibblesBuf.fromBytes(sp.data)
      for lvl in 0 .. STATIC_VID_LEVELS:
        let vid = if lvl == 0: root else: nib.staticVid(lvl)
        let rc = db.txRef.getVtxRc((root, vid))
        if rc.isOk and rc.value[0].vType in Leaves:
          return lvl
      -1

    let before = leafLevel(sB)
    check:
      before == 4
      db.probeLevelOf(accA) == 1

    let tx1 = db.txFrameBegin(db.txRef)
    check tx1.deleteSlot(accA, sA).isOk()
    db.persist(tx1, 2)

    # the promoted branch absorbs the freed nibble into its prefix and keeps its
    # startVid, so the leaves below keep their level - the probe must not move
    check:
      leafLevel(sB) == before
      db.probeLevelOf(accA) == 1
      db.slotBothWays(accA, sB) == 22.u256
      db.slotBothWays(accA, sC) == 33.u256
      db.slotBothWays(accA, sA) == 0.u256

  test "two tries share static vids without interfering":
    let tx = db.txFrameBegin(db.txRef)
    check:
      tx.mergeAccount(accA, account(1)).isOk()
      tx.mergeAccount(accB, account(2)).isOk()
      tx.mergeSlot(accA, slot1, 11.u256).isOk()
      tx.mergeSlot(accA, slot3, 13.u256).isOk()
      tx.mergeSlot(accB, slot1, 21.u256).isOk()
      tx.mergeSlot(accB, slot3, 23.u256).isOk()
    db.persist(tx, 1)
    let
      rootA = db.stoRoot(accA)
      rootB = db.stoRoot(accB)
      svid = NibblesBuf.fromBytes(slot1.data).staticVid(1)
    check:
      rootA != rootB
      db.txRef.getVtxRc((rootA, svid)).isOk()
      db.txRef.getVtxRc((rootB, svid)).isOk()
      db.slotBothWays(accA, slot1) == 11.u256
      db.slotBothWays(accB, slot1) == 21.u256
      db.slotBothWays(accA, slot3) == 13.u256
      db.slotBothWays(accB, slot3) == 23.u256

  test "clear and recreate resets and rebuilds the hint":
    let tx0 = db.txFrameBegin(db.txRef)
    check:
      tx0.mergeAccount(accA, account(1)).isOk()
      tx0.mergeSlot(accA, slot1, 11.u256).isOk()
      tx0.mergeSlot(accA, slot2, 22.u256).isOk()
    db.persist(tx0, 1)
    check db.probeLevelOf(accA) == 0

    let tx1 = db.txFrameBegin(db.txRef)
    check tx1.clearStorage(accA).isOk()
    db.persist(tx1, 2)
    check:
      db.probeLevelOf(accA) == -1
      db.slotBothWays(accA, slot1) == 0.u256

    let tx2 = db.txFrameBegin(db.txRef)
    check tx2.mergeSlot(accA, slot3, 33.u256).isOk()
    db.persist(tx2, 3)
    check:
      db.probeLevelOf(accA) == 0
      db.slotBothWays(accA, slot3) == 33.u256
      db.slotBothWays(accA, slot1) == 0.u256

  test "hint survives the leaf blob and a persisted reopen on RocksDB":
    let leaf = AccLeafRef.init(NibblesBuf.fromBytes(accA.data), account(1), (true, VertexID(99)), 3)
    var buf: VertexBuf
    leaf.blobifyTo(VOID_HASH_KEY, buf)
    let back = AccLeafRef(buf.data().deblobify(VertexRef).expect("leaf"))
    check:
      back.stoHint == 3
      back.stoID == (true, VertexID(99))

    let dir = mkdtemp(prefix = "static_sto_", dir = getAppDir())
    defer:
      try: removeDir(dir) except CatchableError: discard
    proc open(wipe: bool): AristoDbRef =
      let
        dbOpts = DbOptions.init(
          maxOpenFiles = 64, writeBufferSize = 4 * 1024 * 1024, rowCacheSize = 0,
          blockCacheSize = 8 * 1024 * 1024, rdbVtxCacheSize = 1024 * 1024,
          rdbKeyCacheSize = 1024 * 1024, rdbBranchCacheSize = 1024 * 1024,
          maxSnapshots = 2, parallelStateRootComputation = false, threadSafeCaches = false)
        cache = cacheCreateLRU(dbOpts.blockCacheSize, autoClose = true)
        baseDb = RocksDbInstanceRef
          .open(dir, dbOpts.toDbOpts(), @[($VtxCF, dbOpts.toCfOpts(cache, true))], wipe)
          .expect("open")
        rdb = rocksDbBackend(dbOpts, baseDb)
      rdb.initInstance(
        dbOpts.maxSnapshots, false, threadSafeCaches = false,
        accLeavesLruSize = 16, stoLeavesLruSize = 16).expect("aristo db")
      rdb

    block:
      let rdb = open(wipe = true)
      let tx = rdb.txFrameBegin(rdb.txRef)
      check:
        tx.mergeAccount(accA, account(1)).isOk()
        tx.mergeAccount(accB, account(2)).isOk()
        tx.mergeSlot(accA, slot1, 11.u256).isOk()
        tx.mergeSlot(accA, slot3, 13.u256).isOk()
        tx.mergeSlot(accA, slot2, 12.u256).isOk()
        tx.mergeSlot(accA, slot4, 14.u256).isOk()
        tx.mergeSlot(accB, slot1, 21.u256).isOk()
        tx.mergeSlot(accB, slot2, 22.u256).isOk()
      rdb.persist(tx, 1)
      rdb.close()

    block:
      let rdb = open(wipe = false)
      check:
        rdb.probeLevelOf(accA) == 4
        rdb.probeLevelOf(accB) == 0
        rdb.slotBothWays(accA, slot1) == 11.u256
        rdb.slotBothWays(accA, slot2) == 12.u256
        rdb.slotBothWays(accA, slot3) == 13.u256
        rdb.slotBothWays(accA, slot4) == 14.u256
        rdb.slotBothWays(accB, slot1) == 21.u256
        rdb.slotBothWays(accB, slot2) == 22.u256
        rdb.slotBothWays(accA, slotMissing) == 0.u256
      rdb.close()
