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
  tempfile,
  unittest2,
  rocksdb,
  stew/endians2,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_blobify, aristo_constants, aristo_desc],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/
    [rdb_desc, rdb_get, rdb_init, rdb_put],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  bigVid = VertexID(1'u64 shl 48)
  maxPackedVid = VertexID((1'u64 shl 48) - 1)

proc makeHashKey(i: uint64): HashKey =
  var hash: Hash32
  hash.data()[0 .. 7] = i.toBytesBE()
  hash.to(HashKey)

proc openTestBaseDb(basePath: string, opts: DbOptions): RocksDbInstanceRef =
  let cache = cacheCreateLRU(opts.blockCacheSize, autoClose = true)
  RocksDbInstanceRef
    .open(basePath, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], wipe = true)
    .expect("open test RocksDB")

suite "Aristo rdb cache key":
  test "Keys are distinct across roots and positions":
    let
      staticVid = VertexID(2)
      root1 = VertexID(FIRST_DYNAMIC_VID + 1)
      root2 = VertexID(FIRST_DYNAMIC_VID + 2)
      dyn = VertexID(FIRST_DYNAMIC_VID + 3)

    check:
      (root1, staticVid).toCacheKey()[] != (root2, staticVid).toCacheKey()[]
      (STATE_ROOT_VID, staticVid).toCacheKey()[] != (root1, staticVid).toCacheKey()[]
      (STATE_ROOT_VID, dyn).toCacheKey()[] != (dyn, dyn).toCacheKey()[]
      (root1, dyn).toCacheKey()[] != (dyn, root1).toCacheKey()[]
      (root1, dyn).toCacheKey()[] == (root1, dyn).toCacheKey()[]
      hash((root1, dyn).toCacheKey()[]) == hash((root1, dyn).toCacheKey()[])

  test "Upper bits of root and vid are kept":
    let
      lo = VertexID(0x0000_0001_0000_0002'u64)
      hi = VertexID(0x0000_8001_0000_0002'u64)

    check:
      (lo, lo).toCacheKey()[] != (hi, lo).toCacheKey()[]
      (lo, lo).toCacheKey()[] != (lo, hi).toCacheKey()[]
      (hi, lo).toCacheKey()[] != (lo, hi).toCacheKey()[]

  test "Every root and vid bit maps to a distinct key":
    var keys = @[(VertexID(0), VertexID(0)).toCacheKey()[]]
    for i in 0 ..< 48:
      keys.add (VertexID(1'u64 shl i), VertexID(0)).toCacheKey()[]
      keys.add (VertexID(0), VertexID(1'u64 shl i)).toCacheKey()[]

    keys.add (maxPackedVid, maxPackedVid).toCacheKey()[]
    keys.add (maxPackedVid, VertexID(0)).toCacheKey()[]
    keys.add (VertexID(0), maxPackedVid).toCacheKey()[]

    for i in 0 ..< keys.len:
      for j in i + 1 ..< keys.len:
        check keys[i] != keys[j]

  test "Keys beyond 48 bits are not cacheable":
    check:
      (maxPackedVid, maxPackedVid).toCacheKey().isSome()
      (bigVid, VertexID(2)).toCacheKey().isNone()
      (STATE_ROOT_VID, bigVid).toCacheKey().isNone()
      (VertexID(uint64.high), VertexID(uint64.high)).toCacheKey().isNone()

  test "Branch value round trip":
    for (vid, used) in [
      (VertexID(0), 0'u16),
      (VertexID(0), 0xFFFF'u16),
      (VertexID(FIRST_DYNAMIC_VID), 0x8001'u16),
      (maxPackedVid, 0'u16),
      (maxPackedVid, 0xFFFF'u16),
    ]:
      let v = RdbBranchVal.init(vid, used).expect("fits")
      check:
        v.startVid == vid
        v.used == used

  test "Branch value beyond 48 bits is not cacheable":
    check:
      RdbBranchVal.init(bigVid, 0).isNone()
      RdbBranchVal.init(VertexID(uint64.high), 0xFFFF).isNone()
      VertexRef(BranchRef.init(bigVid, 0xFFFF)).toBranchVal().isNone()
      VertexRef(BranchRef.init(maxPackedVid, 0xFFFF)).toBranchVal().isSome()
      VertexRef(ExtBranchRef.init(NibblesBuf.nibble(2), VertexID(2), 1)).toBranchVal().isNone()

  test "Cache keeps static vids under different roots apart":
    var lru: ConcurrentLruCache[RdbCacheKey, int]
    lru.init(16, shardBits = 0)
    defer:
      lru.dispose()

    let
      a = (STATE_ROOT_VID, VertexID(2))
      b = (VertexID(FIRST_DYNAMIC_VID + 1), VertexID(2))

    lru.put(a.toCacheKey()[], 1)
    lru.put(b.toCacheKey()[], 2)

    check:
      lru.peek(a.toCacheKey()[]) == Opt.some(1)
      lru.peek(b.toCacheKey()[]) == Opt.some(2)

  test "Ids beyond the packed range bypass the caches":
    let
      basePath = mkdtemp(prefix = "rdb_cache_key_", dir = getAppDir())
      opts = DbOptions.init(
        maxOpenFiles = 32,
        writeBufferSize = 1024 * 1024,
        rowCacheSize = 0,
        blockCacheSize = 8 * 1024 * 1024,
        rdbVtxCacheSize = 1024 * 1024,
        rdbKeyCacheSize = 1024 * 1024,
        rdbBranchCacheSize = 1024 * 1024,
        maxSnapshots = 2,
      )
    defer:
      try:
        removeDir(basePath)
      except CatchableError:
        discard

    var rdb: RdbInst
    rdb.init(opts, openTestBaseDb(basePath, opts))
    defer:
      rdb.close(wipe = true)

    let
      bigRoot = (bigVid, bigVid)
      bigLeaf = (STATE_ROOT_VID, bigVid)
      smallBranch = (STATE_ROOT_VID, VertexID(2))
      bigStartBranch = (STATE_ROOT_VID, VertexID(3))
      bigRootKey = makeHashKey(1)
      smallBranchKey = makeHashKey(2)
      bigStartKey = makeHashKey(3)

    block:
      let session = rdb.begin()
      check:
        rdb.putVtx(
          session,
          bigRoot,
          VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID), 0x0003'u16)),
          bigRootKey,
        ).isOk()
        rdb.putVtx(
          session,
          bigLeaf,
          VertexRef(
            AccLeafRef.init(
              NibblesBuf.nibble(1'u8),
              AristoAccount(balance: 7.u256, codeHash: EMPTY_CODE_HASH),
              default(StorageID),
            )
          ),
          VOID_HASH_KEY,
        ).isOk()
        rdb.putVtx(
          session,
          smallBranch,
          VertexRef(BranchRef.init(VertexID(FIRST_DYNAMIC_VID + 16), 0x00ff'u16)),
          smallBranchKey,
        ).isOk()
        rdb.putVtx(
          session, bigStartBranch, VertexRef(BranchRef.init(bigVid, 0xffff'u16)), bigStartKey
        ).isOk()
        rdb.commit(session).isOk()

    check:
      rdb.rdBranchLru.len == 1
      rdb.rdVtxLru.len == 1
      rdb.rdKeyLru.len == 2

    block:
      let vtx = rdb.getVtx(bigRoot, {}).expect("getVtx")
      check:
        vtx.vType == Branch
        BranchRef(vtx).startVid == VertexID(FIRST_DYNAMIC_VID)
        BranchRef(vtx).used == 0x0003'u16

      let (key, keyVtx) = rdb.getKey(bigRoot, {}).expect("getKey")
      check:
        key == bigRootKey
        keyVtx.isNil

    block:
      let vtx = rdb.getVtx(bigLeaf, {}).expect("getVtx")
      check:
        vtx.vType == AccLeaf
        AccLeafRef(vtx).account.balance == 7.u256

      let (key, keyVtx) = rdb.getKey(bigLeaf, {}).expect("getKey")
      check:
        key == VOID_HASH_KEY
        keyVtx.vType == AccLeaf

    block:
      var keyvtxs: array[2, (HashKey, VertexRef)]
      check:
        rdb.getKeys([bigRoot, smallBranch], keyvtxs, {}).isOk()
        keyvtxs[0][0] == bigRootKey
        keyvtxs[1][0] == smallBranchKey

    check:
      rdb.rdBranchLru.len == 1
      rdb.rdVtxLru.len == 1
      rdb.rdKeyLru.len == 2

    for flags in [default(set[GetVtxFlag]), {GetVtxFlag.PeekCache}]:
      let vtx = rdb.getVtx(bigStartBranch, flags).expect("getVtx")
      check:
        vtx.vType == Branch
        BranchRef(vtx).startVid == bigVid
        BranchRef(vtx).used == 0xffff'u16

    block:
      rdb.rdVtxLru.del(bigStartBranch.toCacheKey()[])
      check rdb.rdVtxLru.len == 0

      let vtx = rdb.getVtx(bigStartBranch, {}).expect("getVtx")
      check:
        BranchRef(vtx).startVid == bigVid
        rdb.rdBranchLru.len == 1
        rdb.rdVtxLru.len == 1

    block:
      let session = rdb.begin()
      check:
        rdb.putVtx(session, bigRoot, VertexRef(nil), VOID_HASH_KEY).isOk()
        rdb.commit(session).isOk()
        rdb.getVtx(bigRoot, {}).expect("getVtx").isNil
        rdb.getKey(bigRoot, {}).expect("getKey")[0] == VOID_HASH_KEY
