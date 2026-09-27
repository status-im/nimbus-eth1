# Nimbus
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
  std/[importutils, math, os, random, sequtils, strformat, strutils, times],
  tempfile,
  unittest2,
  rocksdb,
  stew/endians2,
  ../../execution_chain/concurrency/lru {.all.},
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_desc],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/
    [rdb_desc, rdb_get, rdb_init, rdb_put],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

privateAccess(LruCache)
privateAccess(ConcurrentLruCache)
privateAccess(Shard)

const
  benchmarkNameWidth = 28
  leafRecordCount = 50_000
  branchRecordCount = 4_096
  readCount = 1_000_000

  capacityBranchCount = 320_000
  capacityExtCount = 12_000
  capacityLeafCount = 96_000
  capacityRootCount = 8
  capacityReadCount = 1_000_000
  capacitySeed = 0x5eed'i64

type
  GetterSample = object
    rvid: RootedVertexID
    vType: VertexType
    hasKey: bool

  BenchmarkStats = object
    elapsed: float
    operations: int
    checksum: uint64

  CapacityCache = enum
    ccBranch = "branch"
    ccVtx = "vtx"
    ccKey = "key"

  CapacityOrder = enum
    coUniform = "uniform"
    coZipf = "zipf"
    coFits = "fits"

  CapacityRecord = object
    rvid: RootedVertexID
    vType: VertexType
    key: HashKey
    tag: uint64

  CapacityResult = object
    entries: int
    capacity: int
    bytes: int
    hits: uint64
    misses: uint64
    elapsed: float
    operations: int

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchmarkNameWidth) & " " & align("elapsed(s)", 10) & " " &
    align("reads/s", 14) & " " & align("us/read", 10)

proc benchmarkLine(name: string, stats: BenchmarkStats): string =
  let
    readsPerSecond = stats.operations.float / stats.elapsed
    microsecondsPerRead = (stats.elapsed * 1_000_000.0) / stats.operations.float
  "  " & alignLeft(name, benchmarkNameWidth) & " " & align(fmt"{stats.elapsed:.4f}", 10) &
    " " & align(fmt"{readsPerSecond:.2f}", 14) & " " &
    align(fmt"{microsecondsPerRead:.4f}", 10)

proc makeHashKey(i: uint64): HashKey =
  var hash: Hash32
  hash.data()[0 .. 7] = i.toBytesBE()
  hash.to(HashKey)

proc makeBenchmarkOpts(): DbOptions =
  DbOptions.init(
    maxOpenFiles = 128,
    writeBufferSize = 8 * 1024 * 1024,
    rowCacheSize = 0,
    blockCacheSize = 64 * 1024 * 1024,
    rdbVtxCacheSize = 2 * 1024 * 1024,
    rdbKeyCacheSize = 4 * 1024 * 1024,
    rdbBranchCacheSize = 2 * 1024 * 1024,
    maxSnapshots = 2,
  )

proc openBenchmarkBaseDb(
    basePath: string, opts: DbOptions, wipe = false
): RocksDbInstanceRef =
  let cache =
    if opts.blockCacheSize > 0:
      cacheCreateLRU(opts.blockCacheSize, autoClose = true)
    else:
      nil

  RocksDbInstanceRef
    .open(basePath, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], wipe)
    .expect("open benchmark RocksDB")

proc populateBenchmarkDb(basePath: string, opts: DbOptions): seq[GetterSample] =
  let baseDb = openBenchmarkBaseDb(basePath, opts, wipe = true)
  var rdb: RdbInst
  rdb.init(opts, baseDb)

  let session = rdb.begin()

  result = newSeqOfCap[GetterSample](leafRecordCount + branchRecordCount)

  for i in 0'u64 ..< branchRecordCount.uint64:
    let
      rvid = (STATE_ROOT_VID, VertexID(2 + i))
      vtx =
        if (i and 1) == 0:
          VertexRef(BranchRef.init(VertexID(100_000 + i * 16), 0x0001'u16))
        else:
          VertexRef(
            ExtBranchRef.init(
              NibblesBuf.nibble(byte(i and 0x0f)),
              VertexID(100_000 + i * 16),
              0x0001'u16,
            )
          )
      key = makeHashKey(i + 1)

    check rdb.putVtx(session, rvid, vtx, key).isOk()
    result.add GetterSample(rvid: rvid, vType: vtx.vType, hasKey: true)

  for i in 0'u64 ..< leafRecordCount.uint64:
    let
      rvid = (STATE_ROOT_VID, VertexID(2 + branchRecordCount.uint64 + i))
      vtx = AccLeafRef.init(
        NibblesBuf.nibble(byte(i and 0x0f)),
        AristoAccount(balance: (i + 1).u256, codeHash: EMPTY_CODE_HASH),
        default(StorageID),
      )

    check rdb.putVtx(session, rvid, vtx, VOID_HASH_KEY).isOk()
    result.add GetterSample(rvid: rvid, vType: vtx.vType, hasKey: false)

  check rdb.commit(session).isOk()
  rdb.close(wipe = false)

proc makeReadOrder(sampleCount: int): seq[int] =
  result = newSeq[int](readCount)
  for i in 0 ..< readCount:
    result[i] = ((i.int64 * 2654435761'i64) mod sampleCount.int64).int

proc runGetVtxBenchmark(
    basePath: string,
    opts: DbOptions,
    samples: openArray[GetterSample],
    readOrder: openArray[int],
    warmCache: bool,
): BenchmarkStats =
  let baseDb = openBenchmarkBaseDb(basePath, opts)
  var rdb: RdbInst
  rdb.init(opts, baseDb)

  if warmCache:
    for index in readOrder:
      let vtx = rdb.getVtx(samples[index].rvid, {}).expect("warm getVtx")
      doAssert vtx.isValid

  let started = epochTime()
  var checksum = 0'u64

  for index in readOrder:
    let sample = samples[index]
    let vtx = rdb.getVtx(sample.rvid, {}).expect("benchmark getVtx")
    doAssert vtx.isValid
    doAssert vtx.vType == sample.vType
    checksum = checksum xor (uint64(vtx.vType.ord) shl 32) xor uint64(sample.rvid.vid)

  result = BenchmarkStats(
    elapsed: epochTime() - started, operations: readOrder.len, checksum: checksum
  )

  rdb.close(wipe = false)

proc runGetKeyBenchmark(
    basePath: string,
    opts: DbOptions,
    samples: openArray[GetterSample],
    readOrder: openArray[int],
    warmCache: bool,
): BenchmarkStats =
  let baseDb = openBenchmarkBaseDb(basePath, opts)
  var rdb: RdbInst
  rdb.init(opts, baseDb)

  if warmCache:
    for index in readOrder:
      let sample = samples[index]
      let (key, vtx) = rdb.getKey(sample.rvid, {}).expect("warm getKey")

      if sample.hasKey:
        doAssert key.isValid
        doAssert not vtx.isValid
      else:
        doAssert not key.isValid
        doAssert vtx.isValid
        doAssert vtx.vType == sample.vType

  let started = epochTime()
  var checksum = 0'u64

  for index in readOrder:
    let sample = samples[index]
    let (key, vtx) = rdb.getKey(sample.rvid, {}).expect("benchmark getKey")

    if sample.hasKey:
      doAssert key.isValid
      doAssert not vtx.isValid
      checksum = checksum xor (uint64(key.len) shl 32) xor uint64(sample.rvid.vid)
    else:
      doAssert not key.isValid
      doAssert vtx.isValid
      doAssert vtx.vType == sample.vType
      checksum = checksum xor (uint64(vtx.vType.ord) shl 32) xor uint64(sample.rvid.vid)

  result = BenchmarkStats(
    elapsed: epochTime() - started, operations: readOrder.len, checksum: checksum
  )

  rdb.close(wipe = false)

func allocatedBytes[K, V](s: LruCache[K, V]): int =
  s.nodesAllocatedLen * sizeof(LruNode[K, V]) + s.bucketsLen * sizeof(LruBucket)

func allocatedBytes[K, V](lru: ConcurrentLruCache[K, V]): int =
  if lru.threadSafe:
    for i in 0 ..< lru.numShards():
      result += lru.shards[i].cache.allocatedBytes()
  else:
    result = lru.cache.allocatedBytes()

proc makeCapacityOpts(): DbOptions =
  DbOptions.init(
    maxOpenFiles = 128,
    writeBufferSize = 8 * 1024 * 1024,
    rowCacheSize = 0,
    blockCacheSize = 256 * 1024 * 1024,
    rdbVtxCacheSize = 8 * 1024 * 1024,
    rdbKeyCacheSize = 12 * 1024 * 1024,
    rdbBranchCacheSize = 8 * 1024 * 1024,
    maxSnapshots = 2,
  )

func capacityRvid(i: int): RootedVertexID =
  let
    slot = uint64(i div capacityRootCount)
    rootIdx = uint64(i mod capacityRootCount)
    root =
      if rootIdx == 0:
        STATE_ROOT_VID
      else:
        VertexID(FIRST_DYNAMIC_VID + rootIdx)
    vid =
      if (slot and 1) == 0:
        VertexID(2 + slot)
      else:
        VertexID(FIRST_DYNAMIC_VID + 1_000_000 + uint64(i))
  (root, vid)

proc populateCapacityDb(basePath: string, opts: DbOptions): seq[CapacityRecord] =
  const total = capacityBranchCount + capacityExtCount + capacityLeafCount
  let baseDb = openBenchmarkBaseDb(basePath, opts, wipe = true)
  var rdb: RdbInst
  rdb.init(opts, baseDb)

  let session = rdb.begin()
  result = newSeqOfCap[CapacityRecord](total)

  for i in 0 ..< total:
    let
      rvid = capacityRvid(i)
      startVid = FIRST_DYNAMIC_VID + 100_000_000 + uint64(i) * 16

    if i < capacityBranchCount:
      let key = makeHashKey(uint64(i) + 1)
      check rdb.putVtx(
        session, rvid, VertexRef(BranchRef.init(VertexID(startVid), 0xffff'u16)), key
      ).isOk()
      result.add CapacityRecord(
        rvid: rvid, vType: VertexType.Branch, key: key, tag: startVid
      )
    elif i < capacityBranchCount + capacityExtCount:
      let key = makeHashKey(uint64(i) + 1)
      check rdb.putVtx(
        session,
        rvid,
        VertexRef(
          ExtBranchRef.init(
            NibblesBuf.nibble(byte(i and 0x0f)), VertexID(startVid), 0xffff'u16
          )
        ),
        key,
      ).isOk()
      result.add CapacityRecord(
        rvid: rvid, vType: VertexType.ExtBranch, key: key, tag: startVid
      )
    else:
      let balance = uint64(i) + 1
      check rdb.putVtx(
        session,
        rvid,
        VertexRef(
          AccLeafRef.init(
            NibblesBuf.nibble(byte(i and 0x0f)),
            AristoAccount(balance: balance.u256, codeHash: EMPTY_CODE_HASH),
            default(StorageID),
          )
        ),
        VOID_HASH_KEY,
      ).isOk()
      result.add CapacityRecord(
        rvid: rvid, vType: VertexType.AccLeaf, key: VOID_HASH_KEY, tag: balance
      )

  check rdb.commit(session).isOk()
  rdb.close(wipe = false)

proc capacityReads(
    n: int, order: CapacityOrder, perm: openArray[int], rng: var Rand
): seq[int] =
  result = newSeq[int](capacityReadCount)
  for i in 0 ..< capacityReadCount:
    result[i] =
      case order
      of coUniform:
        rng.rand(n - 1)
      of coZipf:
        perm[min(n - 1, int(pow(float(n), rng.rand(1.0))) - 1)]
      of coFits:
        rng.rand(n div 4 - 1)

proc capacityCounts(cache: CapacityCache): tuple[hits, misses: uint64] =
  for state in RdbStateType:
    case cache
    of ccBranch:
      result.hits += rdbBranchLruStats[state].get(true)
      result.misses += rdbBranchLruStats[state].get(false)
    of ccVtx:
      for vType in RdbVertexType:
        result.hits += rdbVtxLruStats[state][vType].get(true)
        result.misses += rdbVtxLruStats[state][vType].get(false)
    of ccKey:
      result.hits += rdbKeyLruStats[state].get(true)
      result.misses += rdbKeyLruStats[state].get(false)

proc capacityRead(rdb: var RdbInst, rec: CapacityRecord, cache: CapacityCache) =
  case cache
  of ccBranch, ccVtx:
    let vtx = rdb.getVtx(rec.rvid, {}).expect("capacity getVtx")
    doAssert vtx.vType == rec.vType
    if vtx.vType in Leaves:
      doAssert AccLeafRef(vtx).account.balance == rec.tag.u256
    else:
      doAssert BranchRef(vtx).startVid == VertexID(rec.tag)
  of ccKey:
    let (key, vtx) = rdb.getKey(rec.rvid, {}).expect("capacity getKey")
    doAssert key == rec.key
    doAssert not vtx.isValid

proc runCapacity(
    basePath: string,
    opts: DbOptions,
    records: openArray[CapacityRecord],
    indices: openArray[int],
    cache: CapacityCache,
    order: CapacityOrder,
): CapacityResult =
  let baseDb = openBenchmarkBaseDb(basePath, opts)
  var rdb: RdbInst
  rdb.init(opts, baseDb)

  var
    rng = initRand(capacitySeed + int64(cache.ord * 16 + order.ord))
    perm = toSeq(0 ..< indices.len)
  rng.shuffle(perm)

  let
    warmup = capacityReads(indices.len, order, perm, rng)
    reads = capacityReads(indices.len, order, perm, rng)

  for j in warmup:
    rdb.capacityRead(records[indices[j]], cache)

  let
    before = capacityCounts(cache)
    started = epochTime()

  for j in reads:
    rdb.capacityRead(records[indices[j]], cache)

  let
    elapsed = epochTime() - started
    after = capacityCounts(cache)

  result = CapacityResult(
    hits: after.hits - before.hits,
    misses: after.misses - before.misses,
    elapsed: elapsed,
    operations: reads.len,
  )

  case cache
  of ccBranch:
    result.entries = rdb.rdBranchLru.len
    result.capacity = rdb.rdBranchLru.capacity
    result.bytes = rdb.rdBranchLru.allocatedBytes()
  of ccVtx:
    result.entries = rdb.rdVtxLru.len
    result.capacity = rdb.rdVtxLru.capacity
    result.bytes = rdb.rdVtxLru.allocatedBytes()
  of ccKey:
    result.entries = rdb.rdKeyLru.len
    result.capacity = rdb.rdKeyLru.capacity
    result.bytes = rdb.rdKeyLru.allocatedBytes()

  rdb.close(wipe = false)

proc capacityHeader(): string =
  "  " & alignLeft("cache/order", 16) & " " & align("budget MiB", 10) & " " &
    align("real MiB", 9) & " " & align("entries", 9) & " " & align("capacity", 9) & " " &
    align("hit %", 7) & " " & align("misses", 9) & " " & align("ns/read", 8)

proc capacityLine(
    cache: CapacityCache, order: CapacityOrder, budget: int, r: CapacityResult
): string =
  const mib = float(1024 * 1024)
  let
    total = r.hits + r.misses
    hitRate =
      if total == 0:
        0.0
      else:
        float(r.hits) * 100.0 / float(total)
    nsPerRead = r.elapsed * 1e9 / float(r.operations)
  "  " & alignLeft($cache & "/" & $order, 16) & " " &
    align(fmt"{float(budget) / mib:.1f}", 10) & " " &
    align(fmt"{float(r.bytes) / mib:.2f}", 9) & " " & align($r.entries, 9) & " " &
    align($r.capacity, 9) & " " & align(fmt"{hitRate:.2f}", 7) & " " &
    align($r.misses, 9) & " " & align(fmt"{nsPerRead:.0f}", 8)

suite "Aristo RocksDB getter benchmark":
  test "Benchmark getKey and getVtx":
    let
      basePath = mkdtemp()
      opts = makeBenchmarkOpts()

    defer:
      try:
        removeDir(basePath)
      except CatchableError:
        discard

    let samples = populateBenchmarkDb(basePath, opts)
    check samples.len > 0

    var
      keyedCount = 0
      leafCount = 0
      branchCount = 0

    for sample in samples:
      if sample.hasKey:
        keyedCount.inc
      if sample.vType in Leaves: leafCount.inc else: branchCount.inc

    let readOrder = makeReadOrder(samples.len)

    let
      getVtxCold = runGetVtxBenchmark(basePath, opts, samples, readOrder, false)
      getVtxWarm = runGetVtxBenchmark(basePath, opts, samples, readOrder, true)
      getKeyCold = runGetKeyBenchmark(basePath, opts, samples, readOrder, false)
      getKeyWarm = runGetKeyBenchmark(basePath, opts, samples, readOrder, true)

    debugEcho ""
    debugEcho "Aristo RocksDB getter benchmark"
    debugEcho "  leaf records seeded: ", leafRecordCount
    debugEcho "  branch records seeded: ", branchRecordCount
    debugEcho "  vertices discovered: ", samples.len
    debugEcho "  keyed vertices: ", keyedCount
    debugEcho "  leaf vertices: ", leafCount
    debugEcho "  branch vertices: ", branchCount
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("getVtx cold cache", getVtxCold)
    debugEcho benchmarkLine("getVtx warm cache", getVtxWarm)
    debugEcho benchmarkLine("getKey cold cache", getKeyCold)
    debugEcho benchmarkLine("getKey warm cache", getKeyWarm)
    debugEcho "  checksum(getVtx cold): ", getVtxCold.checksum
    debugEcho "  checksum(getVtx warm): ", getVtxWarm.checksum
    debugEcho "  checksum(getKey cold): ", getKeyCold.checksum
    debugEcho "  checksum(getKey warm): ", getKeyWarm.checksum

    check:
      keyedCount > 0
      leafCount > 0
      branchCount > 0
      getVtxCold.checksum != 0
      getVtxWarm.checksum != 0
      getKeyCold.checksum != 0
      getKeyWarm.checksum != 0

  test "Cache capacity at fixed byte budgets":
    let
      basePath = mkdtemp()
      opts = makeCapacityOpts()

    defer:
      try:
        removeDir(basePath)
      except CatchableError:
        discard

    let records = populateCapacityDb(basePath, opts)

    var indices: array[CapacityCache, seq[int]]
    for i, rec in records:
      if rec.vType == VertexType.Branch:
        indices[ccBranch].add i
      else:
        indices[ccVtx].add i
      if rec.key.isValid:
        indices[ccKey].add i

    let budgets: array[CapacityCache, int] =
      [opts.rdbBranchCacheSize, opts.rdbVtxCacheSize, opts.rdbKeyCacheSize]

    debugEcho ""
    debugEcho "Aristo RocksDB cache capacity benchmark"
    for cache in CapacityCache:
      debugEcho "  ", cache, " working set: ", indices[cache].len
    debugEcho capacityHeader()

    for cache in CapacityCache:
      for order in CapacityOrder:
        let r = runCapacity(basePath, opts, records, indices[cache], cache, order)
        debugEcho capacityLine(cache, order, budgets[cache], r)
        check r.hits + r.misses == uint64(r.operations)
