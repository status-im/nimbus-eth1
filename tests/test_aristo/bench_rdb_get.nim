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
  std/[os, strformat, strutils, times],
  tempfile,
  unittest2,
  rocksdb,
  stew/endians2,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_desc],
  ../../execution_chain/db/aristo/aristo_init/rocks_db/
    [rdb_desc, rdb_get, rdb_init, rdb_put],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  benchmarkNameWidth = 28
  leafRecordCount = 50_000
  branchRecordCount = 4_096
  readCount = 1_000_000

type
  GetterSample = object
    rvid: RootedVertexID
    vType: VertexType
    hasKey: bool

  BenchmarkStats = object
    elapsed: float
    operations: int
    checksum: uint64

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
