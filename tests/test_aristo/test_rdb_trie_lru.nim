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
  std/[cpuinfo, os],
  unittest2,
  tempfile,
  results,
  rocksdb,
  eth/keccak/rapidhash,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_blobify, aristo_desc],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/[rdb_desc, rdb_get, rdb_put],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/rdb_init {.all.},
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const stoRoots = [VertexID(FIRST_DYNAMIC_VID), VertexID(FIRST_DYNAMIC_VID + 1)]

func accRvid(vid: uint64): RootedVertexID =
  (STATE_ROOT_VID, VertexID(vid))

func stoRvid(trie: int, vid: uint64): RootedVertexID =
  (stoRoots[trie], VertexID(vid))

func keyOf(i: int): HashKey =
  var h: Hash32
  h.data[0] = byte(i)
  h.data[31] = 0xaa
  h.to(HashKey)

proc blob(vtx: VertexRef): seq[byte] =
  var buf: VertexBuf
  vtx.blobifyTo(VOID_HASH_KEY, buf)
  @(buf.data())

proc peekVia(lru: var RdbTrieLru[int], rvid: RootedVertexID): Opt[int] =
  lru.withPeek(rvid, value):
    return Opt.some(value)
  Opt.none(int)

proc getVia(lru: var RdbTrieLru[int], rvid: RootedVertexID): Opt[int] =
  lru.withGet(rvid, value):
    return Opt.some(value)
  Opt.none(int)

proc shardCount(threadSafe: bool): int =
  if threadSafe: 1 shl defaultShardBits(countProcessors()) else: 1

proc splitBytes[V](lru: RdbTrieLru[V], threadSafe: bool): int =
  let shards = shardCount(threadSafe)
  ConcurrentLruCache[VertexID, V].realBytes(lru.accSize, shards) +
    ConcurrentLruCache[RootedVertexID, V].realBytes(lru.stoSize, shards)

proc openRdb(dir: string, threadSafe: bool, wipe: bool): RdbInst =
  let
    opts = DbOptions.init(
      maxOpenFiles = 64, writeBufferSize = 4 * 1024 * 1024, rowCacheSize = 0,
      blockCacheSize = 8 * 1024 * 1024, rdbVtxCacheSize = 1024 * 1024,
      rdbKeyCacheSize = 1024 * 1024, rdbBranchCacheSize = 1024 * 1024,
      maxSnapshots = 2, parallelStateRootComputation = false,
      threadSafeCaches = threadSafe)
    cache = cacheCreateLRU(opts.blockCacheSize, autoClose = true)
    baseDb = RocksDbInstanceRef
      .open(dir, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], wipe)
      .expect("open")
  result.init(opts, baseDb)

suite "Aristo RocksDB trie split caches":
  test "Routing keeps the account trie and storage tries apart":
    for threadSafe in [false, true]:
      var lru: RdbTrieLru[int]
      lru.init(4096, 4096, threadSafe)
      lru.put(accRvid(2), 1)
      check:
        lru.acc.len == 1
        lru.sto.len == 0
      lru.put(stoRvid(0, 2), 2)
      lru.put(stoRvid(1, 2), 3)
      check:
        lru.acc.len == 1
        lru.sto.len == 2
        lru.peek(accRvid(2)) == Opt.some(1)
        lru.get(stoRvid(0, 2)) == Opt.some(2)
        lru.peekVia(accRvid(2)) == Opt.some(1)
        lru.peekVia(stoRvid(1, 2)) == Opt.some(3)
        lru.getVia(accRvid(2)) == Opt.some(1)
        lru.getVia(stoRvid(1, 2)) == Opt.some(3)
        lru.peekVia(accRvid(3)).isNone()
        lru.getVia(stoRvid(0, 3)).isNone()
        lru.update(stoRvid(0, 2), 20)
      lru.del(accRvid(2))
      check:
        lru.peek(accRvid(2)).isNone()
        lru.peek(stoRvid(0, 2)) == Opt.some(20)
        lru.peek(stoRvid(1, 2)) == Opt.some(3)
        not lru.update(accRvid(2), 5)
      lru.dispose()

  test "An empty account part routes the account trie to the storage part":
    for threadSafe in [false, true]:
      var lru: RdbTrieLru[int]
      lru.init(0, 4096, threadSafe)
      lru.put(accRvid(2), 1)
      check:
        lru.acc.len == 0
        lru.sto.len == 1
        lru.peek(accRvid(2)) == Opt.some(1)
        lru.hasRoom(accRvid(3))
      lru.dispose()

  test "Eviction and room checks are per trie":
    var lru: RdbTrieLru[int]
    lru.init(4, 4, false)
    for i in 0 ..< 4:
      lru.put(stoRvid(0, uint64(i) + 2), i)
    check:
      not lru.hasRoom(stoRvid(0, 100))
      lru.hasRoom(accRvid(100))
    for i in 0 ..< 16:
      lru.put(accRvid(uint64(i) + 2), i)
    check:
      lru.acc.len == 4
      not lru.hasRoom(accRvid(100))
    for i in 0 ..< 4:
      check lru.peek(stoRvid(0, uint64(i) + 2)) == Opt.some(i)
    lru.dispose()

  test "Clearing keeps the split":
    for threadSafe in [false, true]:
      var lru: RdbTrieLru[int]
      lru.init(4096, 8192, threadSafe)
      lru.put(accRvid(2), 1)
      lru.put(stoRvid(0, 2), 2)
      let (accCap, stoCap) = (lru.acc.capacity, lru.sto.capacity)
      for _ in 0 ..< 2:
        lru.clear(threadSafe)
        check:
          lru.acc.len == 0
          lru.sto.len == 0
          lru.accSize == 4096
          lru.stoSize == 8192
          lru.acc.capacity == accCap
          lru.sto.capacity == stoCap
      lru.put(accRvid(2), 1)
      check lru.peek(accRvid(2)) == Opt.some(1)
      lru.dispose()

  test "VertexID keys hash with rapidhash":
    check:
      hash(VertexID(5)) == cast[Hash](rapidhashNano(cast[array[8, byte]](VertexID(5))))
      hash(VertexID(5)) != hash(VertexID(6))

  test "Split never holds fewer entries or more memory than a single cache":
    template checkSplit(V: typedesc, budget: int, threadSafe: bool) =
      block:
        var lru: RdbTrieLru[V]
        lru.initLru(budget, threadSafe)
        let unsplit = budget div (sizeof(RootedVertexID) + sizeof(V) + lruOverhead)
        check:
          lru.accSize + lru.stoSize >= unsplit
          lru.splitBytes(threadSafe) <=
            ConcurrentLruCache[RootedVertexID, V].realBytes(unsplit, shardCount(threadSafe))
        lru.dispose()

    for threadSafe in [false, true]:
      for mib in [0, 1, 32, 128, 256, 653, 1280, 1331, 2611]:
        let budget = mib * 1024 * 1024
        checkSplit(HashKey, budget, threadSafe)
        checkSplit(VertexBuf, budget, threadSafe)
        checkSplit((VertexID, uint16), budget, threadSafe)

  test "Default budgets split close to the account trie traffic":
    func accShare[V](lru: RdbTrieLru[V]): float =
      lru.accSize.float / float(lru.accSize + lru.stoSize)

    var
      key: RdbTrieLru[HashKey]
      vtx: RdbTrieLru[VertexBuf]
      branch, importBranch: RdbTrieLru[(VertexID, uint16)]
    key.initLru(defaultRdbKeyCacheSize, false)
    vtx.initLru(defaultRdbVtxCacheSize, false)
    branch.initLru(defaultRdbBranchCacheSize, false)
    importBranch.initLru(defaultRdbKeyCacheSize + defaultRdbBranchCacheSize, false)
    check:
      abs(vtx.accShare - 0.276) < 0.005
      abs(key.accShare - 0.333) < 0.005
      abs(branch.accShare - 0.5) < 0.005
      abs(importBranch.accShare - 0.5) < 0.005
    key.dispose()
    vtx.dispose()
    branch.dispose()
    importBranch.dispose()

  test "RdbInst reads and writes both tries through the split caches":
    for threadSafe in [false, true]:
      let dir = mkdtemp(prefix = "rdb_trie_lru_", dir = getAppDir())
      defer:
        try: removeDir(dir) except CatchableError: discard
      var rdb = openRdb(dir, threadSafe, wipe = true)
      let
        accBranch = VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID + 10), 0x0003'u16))
        stoBranch = VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID + 20), 0x0030'u16))
        accLeaf = VertexRef(AccLeafRef.init(
          NibblesBuf.nibble(1), AristoAccount(nonce: 1, codeHash: EMPTY_CODE_HASH),
          default(StorageID)))
        stoLeaf0 = VertexRef(StoLeafRef.init(NibblesBuf.nibble(2), 7.u256))
        stoLeaf1 = VertexRef(StoLeafRef.init(NibblesBuf.nibble(3), 8.u256))
        writes = [
          (accRvid(10), accBranch, keyOf(1)),
          (stoRvid(0, 10), stoBranch, keyOf(2)),
          (accRvid(11), accLeaf, VOID_HASH_KEY),
          (stoRvid(0, 11), stoLeaf0, VOID_HASH_KEY),
          (stoRvid(1, 11), stoLeaf1, VOID_HASH_KEY),
        ]

      block:
        let session = rdb.begin()
        for (rvid, vtx, key) in writes:
          check rdb.putVtx(session, rvid, vtx, key).isOk()
        check rdb.commit(session).isOk()
      check:
        rdb.rdBranchLru.acc.len == 1
        rdb.rdBranchLru.sto.len == 1
        rdb.rdVtxLru.acc.len == 1
        rdb.rdVtxLru.sto.len == 2
        rdb.rdKeyLru.acc.len == 1
        rdb.rdKeyLru.sto.len == 1

      for round in 0 ..< 2:
        for (rvid, vtx, key) in writes:
          check rdb.getVtx(rvid, {}).expect("getVtx").blob() == vtx.blob()
          let (gotKey, gotVtx) = rdb.getKey(rvid, {}).expect("getKey")
          if key.isValid:
            check gotKey == key
          else:
            check:
              not gotKey.isValid
              gotVtx.blob() == vtx.blob()
        var
          rvids: array[5, RootedVertexID]
          keyvtxs: array[5, (HashKey, VertexRef)]
        for i, (rvid, _, _) in writes:
          rvids[i] = rvid
        check rdb.getKeys(rvids, keyvtxs, {}).isOk()
        for i, (_, vtx, key) in writes:
          if key.isValid:
            check keyvtxs[i][0] == key
          else:
            check keyvtxs[i][1].blob() == vtx.blob()
        rdb.rdKeyLru.clear(threadSafe)
        rdb.rdVtxLru.clear(threadSafe)
        rdb.rdBranchLru.clear(threadSafe)

      block:
        let session = rdb.begin()
        check:
          rdb.putVtx(session, accRvid(11), VertexRef(nil), VOID_HASH_KEY).isOk()
          rdb.commit(session).isOk()
      check:
        not rdb.getVtx(accRvid(11), {}).expect("getVtx").isValid
        rdb.getVtx(stoRvid(0, 11), {}).expect("getVtx").blob() == stoLeaf0.blob()
        rdb.getVtx(stoRvid(1, 11), {}).expect("getVtx").blob() == stoLeaf1.blob()

      block:
        let session = rdb.begin()
        check rdb.putVtx(session, accRvid(12), accLeaf, VOID_HASH_KEY).isOk()
        let sizes = (rdb.rdVtxLru.accSize, rdb.rdVtxLru.stoSize)
        rdb.rollback(session)
        check:
          rdb.rdVtxLru.acc.len == 0
          rdb.rdVtxLru.sto.len == 0
          rdb.rdKeyLru.acc.len == 0
          rdb.rdBranchLru.sto.len == 0
          (rdb.rdVtxLru.accSize, rdb.rdVtxLru.stoSize) == sizes
          rdb.getVtx(stoRvid(0, 11), {}).expect("getVtx").isValid
          rdb.rdVtxLru.sto.len == 1
      rdb.close(wipe = false)

  test "Peek-mode key reads only fill a trie part with room":
    let dir = mkdtemp(prefix = "rdb_trie_lru_", dir = getAppDir())
    defer:
      try: removeDir(dir) except CatchableError: discard
    var rdb = openRdb(dir, false, wipe = true)
    block:
      let session = rdb.begin()
      for i in 0 ..< 3:
        check rdb.putVtx(
          session, accRvid(uint64(i) + 10),
          VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID + 100), 0x0003'u16)),
          keyOf(i)).isOk()
      check:
        rdb.putVtx(
          session, stoRvid(0, 10),
          VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID + 200), 0x0003'u16)),
          keyOf(9)).isOk()
        rdb.commit(session).isOk()
    rdb.rdKeyLru.dispose()
    rdb.rdKeyLru.init(2, 8, false)
    for i in 0 ..< 3:
      check rdb.getKey(accRvid(uint64(i) + 10), {PeekCache}).expect("getKey")[0] == keyOf(i)
    check:
      rdb.rdKeyLru.acc.len == 2
      rdb.getKey(stoRvid(0, 10), {PeekCache}).expect("getKey")[0] == keyOf(9)
      rdb.rdKeyLru.sto.len == 1
    rdb.close(wipe = false)
