# nimbus-eth1
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.used.}

import
  std/[hashes, os, random, sets],
  tempfile,
  unittest2,
  rocksdb,
  stew/endians2,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/aristo_desc,
  ../../execution_chain/db/aristo/aristo_init/rocks_db/
    [rdb_desc, rdb_get, rdb_init, rdb_put],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  R = FIRST_DYNAMIC_VID
  M = 1'u64 shl 63
  stoA = VertexID(R + 1)
  stoB = VertexID(R + 2)
  collideDv = M - (((M div R) * R) and (M - 1))
  collideA = (VertexID(R + 12345), VertexID(1))
  collideB = (VertexID(R + 12345 + M div R), VertexID(1 + collideDv))

func firstVidAtLevel(level: int): uint64 =
  result = uint64(FIRST_STATIC_VID)
  for i in 0 ..< level:
    result += 1'u64 shl (i * 4)

func makeHashKey(i: uint64): HashKey =
  var hash: Hash32
  hash.data()[0 .. 7] = i.toBytesBE()
  hash.to(HashKey)

template shardOf(rvid: RootedVertexID): int =
  int(cast[uint64](hash(rvid.cacheKey()[0])) shr 58)

template peek[V](
    lru: var ConcurrentLruCache[RdbCacheKey, V], rvid: RootedVertexID
): Opt[V] =
  var r = Opt.none(V)
  lru.withPeek(rvid, cached):
    r = Opt.some(cached)
  r

template get[V](
    lru: var ConcurrentLruCache[RdbCacheKey, V], rvid: RootedVertexID
): Opt[V] =
  var r = Opt.none(V)
  lru.withGet(rvid, cached):
    r = Opt.some(cached)
  r

suite "Aristo RocksDB cache keys":
  test "node layout":
    check:
      sizeof(RdbKeyVal) == 40
      sizeof(RdbBranchVal) == 16
      sizeof(tuple[next, prev: uint32, key: RdbCacheKey, value: RdbKeyVal]) == 56
      sizeof(tuple[next, prev: uint32, key: RdbCacheKey, value: RdbBranchVal]) == 32

  test "hash spreads both kinds over the shards":
    var rng = initRand(1)
    for dynamic in [false, true]:
      var buckets: array[64, int]
      for _ in 0 ..< 100_000:
        let rvid =
          if dynamic:
            (stoA, VertexID(R + uint64(rng.rand(6_000_000_000))))
          else:
            (STATE_ROOT_VID, VertexID(rng.rand(1 .. int(R) - 1)))
        inc buckets[rvid.shardOf()]
      check:
        min(buckets) > 0
        max(buckets) < 3_000

  test "key and check identify every pair exactly":
    let
      roots = [
        STATE_ROOT_VID, VertexID(R), VertexID((1'u64 shl 31) + 7),
        VertexID((5'u64 shl 31) + 12345), VertexID(10_895_322_789'u64),
      ]
      vids = [
        VertexID(1), VertexID(2), VertexID(17), VertexID(18), VertexID(273),
        VertexID(R - 1), VertexID(R), VertexID(R + 1), VertexID(10_895_322_789'u64),
      ]
    var
      seen: HashSet[(uint64, uint32)]
      kindOk = true
    for root in roots:
      for vid in vids:
        let (k, c) = (root, vid).cacheKey()
        seen.incl((uint64(k), c))
        if ((uint64(k) and M) != 0) != (uint64(vid) < R):
          kindOk = false
    check:
      seen.len == roots.len * vids.len
      kindOk

  test "colliding keys never return the wrong value":
    let
      a = collideA
      b = collideB
      (ka, ca) = a.cacheKey()
      (kb, cb) = b.cacheKey()
    check:
      1 + collideDv < R
      ka == kb
      ca != cb

    var lru: RdbKeyLru
    lru.init(16, shardBits = 0, threadSafe = false)
    lru.put(a, makeHashKey(1))
    check lru.get(a).get().key == makeHashKey(1)
    lru.put(b, makeHashKey(2))
    check:
      lru.peek(a).isNone()
      lru.get(a).isNone()
      lru.get(b).get().key == makeHashKey(2)
      lru.len == 1
      not lru.update((stoB, VertexID(7)), makeHashKey(3))
      lru.update(a, makeHashKey(4))
      lru.get(a).get().key == makeHashKey(4)
      lru.get(b).isNone()
    lru.del(b)
    check:
      lru.get(a).isNone()
      lru.len == 0
    lru.dispose()

  test "static and dynamic keys never collide":
    var
      rng = initRand(2)
      statics: HashSet[uint64]
      collisions = 0
    for _ in 0 ..< 1_000_000:
      statics.incl uint64(
        (STATE_ROOT_VID, VertexID(rng.rand(1 .. int(R) - 1))).cacheKey()[0])
    for _ in 0 ..< 1_000_000:
      let vid = VertexID(R + uint64(rng.rand(6_500_000_000)))
      if uint64((stoA, vid).cacheKey()[0]) in statics:
        inc collisions
    check collisions == 0

  test "cross-class partners sit at level 7 or deeper":
    var smallest = high(uint64)
    for k in 1'u64 .. 40'u64:
      let d0 = k * (M div R) + (k * (M mod R)) div R
      for d in d0 - 1 .. d0 + 1:
        let rem = (d * R) and (M - 1)
        for dv in [rem, M - rem]:
          if 0 < dv and dv < R:
            smallest = min(smallest, dv)
    check smallest >= firstVidAtLevel(7)

  test "same static vid under three roots":
    for threadSafe in [false, true]:
      var lru: RdbBranchLru
      if threadSafe:
        lru.init(64)
      else:
        lru.init(64, shardBits = 0, threadSafe = false)
      let rvids = [(STATE_ROOT_VID, VertexID(5)), (stoA, VertexID(5)), (stoB, VertexID(5))]
      for i, rvid in rvids:
        lru.put(rvid, VertexID(100 + i), uint16(i + 1))
      for i, rvid in rvids:
        let v = lru.get(rvid)
        check:
          v.isSome()
          v.get().startVid == VertexID(100 + i)
          v.get().used == uint16(i + 1)
      check lru.update(rvids[1], VertexID(200), 9'u16)
      lru.del(rvids[2])
      check:
        lru.peek(rvids[0]).get().startVid == VertexID(100)
        lru.peek(rvids[1]).get().startVid == VertexID(200)
        lru.peek(rvids[1]).get().used == 9
        lru.peek(rvids[2]).isNone()
        lru.len == 2
      lru.dispose()

  test "RdbInst serves the right vertex and key per trie":
    for threadSafe in [false, true]:
      let
        dir = mkdtemp()
        opts = DbOptions.init(
          maxOpenFiles = 64, writeBufferSize = 4 * 1024 * 1024, rowCacheSize = 0,
          blockCacheSize = 8 * 1024 * 1024, rdbVtxCacheSize = 1024 * 1024,
          rdbKeyCacheSize = 1024 * 1024, rdbBranchCacheSize = 1024 * 1024,
          maxSnapshots = 2, threadSafeCaches = threadSafe)
        cache = cacheCreateLRU(opts.blockCacheSize, autoClose = true)
        baseDb = RocksDbInstanceRef
          .open(dir, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], true)
          .expect("open")
      defer:
        removeDir(dir)
      var rdb: RdbInst
      rdb.init(opts, baseDb)

      let
        rvids = [
          (STATE_ROOT_VID, VertexID(2)), (stoA, VertexID(2)), (stoB, VertexID(2)),
          collideA, collideB,
        ]
        vtxs = [
          VertexRef(BranchRef.init(VertexID(100), 0x0001'u16)),
          VertexRef(BranchRef.init(VertexID(200), 0x0003'u16)),
          VertexRef(StoLeafRef.init(NibblesBuf.nibble(3), 7.u256)),
          VertexRef(BranchRef.init(VertexID(300), 0x0005'u16)),
          VertexRef(BranchRef.init(VertexID(400), 0x0007'u16)),
        ]
        keys = [makeHashKey(1), makeHashKey(2), VOID_HASH_KEY, makeHashKey(3), makeHashKey(4)]

      template checkAll(flags: set[GetVtxFlag]) =
        for i in 0 ..< rvids.len:
          let vtx = rdb.getVtx(rvids[i], flags).expect("vtx")
          check vtx.vType == vtxs[i].vType
          if vtx.vType == Branch:
            check:
              BranchRef(vtx).startVid == BranchRef(vtxs[i]).startVid
              BranchRef(vtx).used == BranchRef(vtxs[i]).used
          let (key, leaf) = rdb.getKey(rvids[i], flags).expect("key")
          check:
            key == keys[i]
            leaf.isValid == (vtx.vType in Leaves)
        var keyvtxs: array[rvids.len, (HashKey, VertexRef)]
        check rdb.getKeys(rvids, keyvtxs, flags).isOk()
        for i in 0 ..< rvids.len:
          check keyvtxs[i][0] == keys[i]

      block:
        let session = rdb.begin()
        for i in 0 ..< rvids.len:
          check rdb.putVtx(session, rvids[i], vtxs[i], keys[i]).isOk()
        check rdb.commit(session).isOk()

      checkAll({})
      rdb.rollback(rdb.begin())
      check rdb.rdBranchLru.len == 0
      checkAll({PeekCache})
      check rdb.rdBranchLru.len == 0
      checkAll({})
      check rdb.rdBranchLru.len == 3

      block:
        let session = rdb.begin()
        check rdb.putVtx(session, rvids[1], VertexRef(nil), VOID_HASH_KEY).isOk()
        check rdb.putVtx(session, collideA, VertexRef(nil), VOID_HASH_KEY).isOk()
        check rdb.commit(session).isOk()
      check:
        not rdb.getVtx(rvids[1], {}).expect("vtx").isValid
        rdb.getKey(rvids[1], {}).expect("key")[0] == VOID_HASH_KEY
        BranchRef(rdb.getVtx(rvids[0], {}).expect("vtx")).startVid == VertexID(100)
        rdb.getKey(rvids[0], {}).expect("key")[0] == keys[0]
        rdb.getVtx(rvids[2], {}).expect("vtx").vType == StoLeaf
        not rdb.getVtx(collideA, {}).expect("vtx").isValid
        rdb.getKey(collideA, {}).expect("key")[0] == VOID_HASH_KEY
        BranchRef(rdb.getVtx(collideB, {}).expect("vtx")).startVid == VertexID(400)
        rdb.getKey(collideB, {}).expect("key")[0] == keys[4]

      rdb.close(wipe = false)
