# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[algorithm, cpuinfo, monotimes, os, strformat, times],
  tempfile,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[
    aristo_compute, aristo_merge, aristo_desc, aristo_tx_frame,
  ],
  ../../execution_chain/db/aristo/aristo_init/persistent,
  ../../execution_chain/db/aristo/aristo_init/rocks_db/rdb_desc,
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  BASE_ACCOUNTS = 2_000_000
  STEADY_BLOCKS = 50
  STEADY_WARMUP = 10
  STEADY_ACCOUNTS_PER_BLOCK = 2_000
  COLD_REPEATS = 3

let NUM_THREADS = max(countProcessors(), 2)

let benchTmpDir = getAppDir() / "bench_tmp"

var benchTaskpool: Taskpool

proc makeOpts(parallel = false): DbOptions =
  DbOptions.init(
    maxOpenFiles = 512,
    writeBufferSize = 64 * 1024 * 1024,
    rowCacheSize = 0,
    blockCacheSize = 256 * 1024 * 1024,
    rdbVtxCacheSize = 64 * 1024 * 1024,
    rdbKeyCacheSize = 128 * 1024 * 1024,
    rdbBranchCacheSize = 64 * 1024 * 1024,
    maxSnapshots = 2,
    parallelStateRootComputation = parallel,
    threadSafeCaches = parallel,
  )

proc openBaseDb(basePath: string, opts: DbOptions, wipe = false): RocksDbInstanceRef =
  let cache =
    if opts.blockCacheSize > 0:
      cacheCreateLRU(opts.blockCacheSize, autoClose = true)
    else:
      nil

  RocksDbInstanceRef
    .open(basePath, opts.toDbOpts(), @[($VtxCF, opts.toCfOpts(cache, true))], wipe)
    .expect("open benchmark RocksDB")

proc openAristoDb(basePath: string, opts: DbOptions, wipe = false): AristoDbRef =
  let db = AristoDbRef.init(opts, openBaseDb(basePath, opts, wipe)).expect("aristo db")
  if opts.parallelStateRootComputation:
    doAssert not benchTaskpool.isNil()
    db.taskpool = benchTaskpool
  db

proc mix(x: uint64): uint64 =
  var z = x + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc path(i: uint64): Hash32 =
  var b: array[32, byte]
  for j in 0'u64 ..< 4:
    let z = mix(i * 4 + j)
    copyMem(addr b[j * 8], unsafeAddr z, 8)
  cast[Hash32](b)

var pathCounter: uint64

proc addAccounts(txFrame: AristoTxRef, n: int) =
  for _ in 0 ..< n:
    let p = path(pathCounter)
    inc pathCounter
    doAssert txFrame.mergeAccount(
      p, AristoAccount(balance: pathCounter.u256(), codeHash: EMPTY_CODE_HASH)
    ).isOk()

proc persistFrame(db: AristoDbRef, txFrame: AristoTxRef, blockNumber: uint64) =
  txFrame.checkpoint(blockNumber, skipSnapshot = true)
  let batch = db.putBegFn()[]
  db.persist(batch, txFrame)
  doAssert db.putEndFn(batch).isOk()

proc buildBaseDb(basePath: string, opts: DbOptions, withKeys: bool) =
  pathCounter = 0
  let db = openAristoDb(basePath, opts, wipe = true)
  var txFrame = db.txRef
  txFrame.addAccounts(BASE_ACCOUNTS)
  if withKeys:
    doAssert txFrame.computeStateRoot(skipLayers = false).isOk()
  db.persistFrame(txFrame, 1)
  db.closeFn(wipe = false)

proc ms(d: Duration): float =
  d.inNanoseconds.float / 1e6

proc median(xs: var seq[float]): float =
  xs.sort()
  xs[xs.len div 2]

proc withDbCopy(srcPath: string, opts: DbOptions, body: proc(db: AristoDbRef)) =
  let dir = mkdtemp(dir = benchTmpDir)
  try:
    removeDir(dir)
    copyDir(srcPath, dir)
    let db = openAristoDb(dir, opts)
    body(db)
    db.closeFn(wipe = false)
  finally:
    try:
      removeDir(dir)
    except CatchableError:
      discard

proc runCold(srcPath: string, opts: DbOptions, useMultiGet: bool): (float, Hash32) =
  var
    elapsed: float
    root: Hash32
  withDbCopy(srcPath, opts) do (db: AristoDbRef):
    if not useMultiGet:
      db.getKeysFn = nil
    let t0 = getMonoTime()
    let res = db.baseTxFrame().computeStateRoot(skipLayers = true)
    elapsed = ms(getMonoTime() - t0)
    doAssert res.isOk()
    root = res[].to(Hash32)
  (elapsed, root)

proc runSteady(srcPath: string, opts: DbOptions, useMultiGet: bool): (float, Hash32) =
  var
    meanMs: float
    root: Hash32
  withDbCopy(srcPath, opts) do (db: AristoDbRef):
    if not useMultiGet:
      db.getKeysFn = nil
    pathCounter = BASE_ACCOUNTS
    var
      txFrame = db.baseTxFrame()
      times: seq[float]
    for blk in 1 .. STEADY_BLOCKS:
      txFrame = db.txFrameBegin(txFrame)
      txFrame.addAccounts(STEADY_ACCOUNTS_PER_BLOCK)
      let t0 = getMonoTime()
      let res = txFrame.computeStateRoot(skipLayers = false)
      times.add ms(getMonoTime() - t0)
      doAssert res.isOk()
      root = res[].to(Hash32)
      txFrame.checkpoint(uint64(blk + 1), skipSnapshot = false)
    var s = 0.0
    for i in STEADY_WARMUP ..< times.len:
      s += times[i]
    meanMs = s / float(times.len - STEADY_WARMUP)
  (meanMs, root)

proc runScenario(
    name: string,
    srcPath: string,
    opts: DbOptions,
    repeats: int,
    scenario: proc(srcPath: string, opts: DbOptions, useMultiGet: bool): (float, Hash32),
): (float, float) =
  var
    singleTimes, multiTimes: seq[float]
    singleRoot, multiRoot: Hash32
  for _ in 0 ..< repeats:
    let (t, r) = scenario(srcPath, opts, false)
    singleTimes.add t
    singleRoot = r
    let (t2, r2) = scenario(srcPath, opts, true)
    multiTimes.add t2
    multiRoot = r2
  doAssert singleRoot == multiRoot, "single-get and multi-get roots differ!"
  let
    s = median(singleTimes)
    m = median(multiTimes)
  echo &"{name}: single-get {s:9.2f} ms | multiget {m:9.2f} ms | speedup {s / m:5.2f}x"
  (s, m)

let
  serialOpts = makeOpts()
  parallelOpts = makeOpts(parallel = true)
  coldPath = mkdtemp(dir = benchTmpDir)
  steadyPath = mkdtemp(dir = benchTmpDir)
  coldName = "cold full-trie root (skipLayers)   "
  steadyName = &"steady-state (mean/root, {STEADY_BLOCKS - STEADY_WARMUP} blocks) "

try:
  echo &"building base db without keys ({BASE_ACCOUNTS} accounts)..."
  buildBaseDb(coldPath, serialOpts, withKeys = false)
  echo &"building base db with keys ({BASE_ACCOUNTS} accounts)..."
  buildBaseDb(steadyPath, serialOpts, withKeys = true)

  echo "\nserial state root computation"
  let
    (coldSerialSingle, coldSerialMulti) =
      runScenario(coldName, coldPath, serialOpts, COLD_REPEATS, runCold)
    (steadySerialSingle, steadySerialMulti) =
      runScenario(steadyName, steadyPath, serialOpts, 1, runSteady)

  benchTaskpool = Taskpool.new(numThreads = NUM_THREADS)

  echo &"\nparallel state root computation ({NUM_THREADS} threads)"
  let
    (coldParSingle, coldParMulti) =
      runScenario(coldName, coldPath, parallelOpts, COLD_REPEATS, runCold)
    (steadyParSingle, steadyParMulti) =
      runScenario(steadyName, steadyPath, parallelOpts, 1, runSteady)

  echo "\nparallel speedup over serial"
  echo &"{coldName}: single-get {coldSerialSingle / coldParSingle:5.2f}x" &
    &" | multiget {coldSerialMulti / coldParMulti:5.2f}x"
  echo &"{steadyName}: single-get {steadySerialSingle / steadyParSingle:5.2f}x" &
    &" | multiget {steadySerialMulti / steadyParMulti:5.2f}x"
finally:
  if not benchTaskpool.isNil():
    benchTaskpool.shutdown()
  try:
    removeDir(coldPath)
    removeDir(steadyPath)
    removeDir(benchTmpDir)
  except CatchableError:
    discard
