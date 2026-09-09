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
  std/[monotimes, os, strformat, times],
  tempfile,
  results,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_desc, aristo_fetch, aristo_merge, aristo_tx_frame],
  ../../execution_chain/db/aristo/aristo_init/[init_common, rocks_db],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  SCALE {.intdefine.} = 10
  ACCOUNTS = 2_000_000 * SCALE
  CONTRACTS = 100_000 * SCALE
  SLOTS_PER_CONTRACT = 32
  BIG_CONTRACTS = 10 * SCALE
  BIG_SLOTS = 65_536
  LEAVES_PER_BLOCK = 1_000_000
  READS = 200_000
  ROUNDS = 2
  MINIMAL_CACHES {.booldefine.} = false
    ## Shrink the Aristo vertex/key/branch LRUs to 1 MiB and the leaf LRUs to
    ## 1024 entries so reads are served by RocksDB alone; its caches are unchanged
  LEAF_LRU_SIZES =
    when MINIMAL_CACHES: [1024] else: [1024, 1024 * 1024]
  BUILD_INDEX {.booldefine.} = true
    ## Build the database without the leaf index (master layout) and run only
    ## the walk strategy, for a true master baseline at the same scale

type
  Workload = enum
    AccountHit = "account hit"
    AccountMiss = "account miss"
    SlotHit = "slot hit"
    SlotMiss = "slot miss"
    BigSlotHit = "big slot hit"
    BigSlotMiss = "big slot miss"

  ReadStats = object
    usPerOp: float
    checksum: uint64

let benchTmpDir = mkdtemp(prefix = "bench_leaf_", dir = getEnv("BENCH_DIR", getAppDir()))

proc makeDbOpts(): DbOptions =
  DbOptions.init(
    maxOpenFiles = 512,
    writeBufferSize = 64 * 1024 * 1024,
    rowCacheSize = 0,
    blockCacheSize = 256 * 1024 * 1024,
    rdbVtxCacheSize = (if MINIMAL_CACHES: 1 else: 64) * 1024 * 1024,
    rdbKeyCacheSize = (if MINIMAL_CACHES: 1 else: 128) * 1024 * 1024,
    rdbBranchCacheSize = (if MINIMAL_CACHES: 1 else: 64) * 1024 * 1024,
    maxSnapshots = 2,
    parallelStateRootComputation = false,
    threadSafeCaches = false,
  )

proc openBaseDb(basePath: string, dbOpts: DbOptions, wipe: bool): RocksDbInstanceRef =
  let cache = cacheCreateLRU(dbOpts.blockCacheSize, autoClose = true)
  RocksDbInstanceRef
    .open(basePath, dbOpts.toDbOpts(), @[($VtxCF, dbOpts.toCfOpts(cache, true))], wipe)
    .expect("open benchmark RocksDB")

proc openAristoDb(
    basePath: string, dbOpts: DbOptions, wipe, directLeafFetch: bool, leafLruSize: int
): (AristoDbRef, RocksDbInstanceRef) =
  let
    baseDb = openBaseDb(basePath, dbOpts, wipe)
    db = rocksDbBackend(dbOpts, baseDb)
  db.initInstance(
    dbOpts.maxSnapshots,
    dbOpts.parallelStateRootComputation,
    threadSafeCaches = dbOpts.threadSafeCaches,
    accLeavesLruSize = leafLruSize,
    stoLeavesLruSize = leafLruSize,
    stoStatic = directLeafFetch,
  ).expect("aristo db")
  (db, baseDb)

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

template contractPath(c: uint64): Hash32 =
  path(c)

template eoaPath(i: uint64): Hash32 =
  path(CONTRACTS.uint64 + i)

template missingAccountPath(i: uint64): Hash32 =
  path(2_000_000_000'u64 + i)

template slotPath(c, s: uint64): Hash32 =
  path(1_000_000_000'u64 + c * SLOTS_PER_CONTRACT + s)

template missingSlotPath(i: uint64): Hash32 =
  path(3_000_000_000'u64 + i)

template bigContractPath(c: uint64): Hash32 =
  path(4_000_000_000'u64 + c)

template bigSlotPath(c, s: uint64): Hash32 =
  path(5_000_000_000'u64 + c * BIG_SLOTS + s)

template missingBigSlotPath(i: uint64): Hash32 =
  path(6_000_000_000'u64 + i)

proc ms(d: Duration): float =
  d.inNanoseconds.float / 1e6

proc dirSize(dir: string): int64 =
  for f in walkDirRec(dir):
    result += getFileSize(f)

proc persistFrame(db: AristoDbRef, txFrame: AristoTxRef, blockNumber: uint64): float =
  txFrame.checkpoint(blockNumber, skipSnapshot = true)
  let t0 = getMonoTime()
  let batch = db.putBegFn()[]
  db.persist(batch, txFrame)
  doAssert db.putEndFn(batch).isOk()
  ms(getMonoTime() - t0)

proc buildDb(basePath: string, dbOpts: DbOptions) =
  let (db, baseDb) = openAristoDb(basePath, dbOpts, wipe = true, directLeafFetch = true, 1024)
  var
    txFrame = db.txFrameBegin(db.txRef)
    blockNumber = 1'u64
    leavesInBlock = 0
    mergeMs = 0.0
    persistMs = 0.0

  template flushIfFull() =
    if leavesInBlock >= LEAVES_PER_BLOCK:
      persistMs += db.persistFrame(txFrame, blockNumber)
      inc blockNumber
      leavesInBlock = 0
      txFrame = db.txFrameBegin(db.txRef)

  var t0 = getMonoTime()
  for c in 0'u64 ..< CONTRACTS:
    doAssert txFrame.mergeAccount(
      contractPath(c), AristoAccount(nonce: 1, balance: c.u256, codeHash: EMPTY_CODE_HASH)
    ).isOk()
    inc leavesInBlock
    for s in 0'u64 ..< SLOTS_PER_CONTRACT:
      doAssert txFrame.mergeSlot(contractPath(c), slotPath(c, s), (c * 100 + s + 1).u256).isOk()
      inc leavesInBlock
    mergeMs += ms(getMonoTime() - t0)
    flushIfFull()
    t0 = getMonoTime()

  for c in 0'u64 ..< BIG_CONTRACTS:
    doAssert txFrame.mergeAccount(
      bigContractPath(c), AristoAccount(nonce: 1, balance: c.u256, codeHash: EMPTY_CODE_HASH)
    ).isOk()
    inc leavesInBlock
    for s in 0'u64 ..< BIG_SLOTS:
      doAssert txFrame.mergeSlot(bigContractPath(c), bigSlotPath(c, s), (c * 100_000 + s + 1).u256).isOk()
      inc leavesInBlock
    mergeMs += ms(getMonoTime() - t0)
    flushIfFull()
    t0 = getMonoTime()

  for i in 0'u64 ..< ACCOUNTS:
    doAssert txFrame.mergeAccount(
      eoaPath(i), AristoAccount(balance: (i + 1).u256, codeHash: EMPTY_CODE_HASH)
    ).isOk()
    inc leavesInBlock
    mergeMs += ms(getMonoTime() - t0)
    flushIfFull()
    t0 = getMonoTime()

  if leavesInBlock > 0:
    persistMs += db.persistFrame(txFrame, blockNumber)

  let rawSize = dirSize(basePath)
  t0 = getMonoTime()
  let vtxCol = baseDb.db.getColFamily($VtxCF).expect("vertex column family")
  baseDb.db.compactRange([], [], vtxCol.handle()).expect("compaction")
  let compactMs = ms(getMonoTime() - t0)

  db.close()

  echo &"  merge {mergeMs:9.1f} ms | persist {persistMs:9.1f} ms" &
    &" | blocks {blockNumber} | size {rawSize div (1024 * 1024)} MiB raw," &
    &" {dirSize(basePath) div (1024 * 1024)} MiB compacted in {compactMs:7.1f} ms"

proc runReads(
    db: AristoDbRef, workload: Workload, offset: uint64
): ReadStats =
  let txFrame = db.txRef
  var checksum = 0'u64
  let t0 = getMonoTime()
  for i in 0'u64 ..< READS:
    let r = mix(offset + i)
    case workload
    of AccountHit:
      let acc = txFrame.fetchAccount(eoaPath(r mod ACCOUNTS)).expect("existing account")
      checksum += acc.balance.truncate(uint64)
    of AccountMiss:
      let rc = txFrame.fetchAccount(missingAccountPath(r))
      doAssert rc.isErr() and rc.error == FetchPathNotFound
      inc checksum
    of SlotHit:
      let
        c = r mod CONTRACTS
        s = mix(r) mod SLOTS_PER_CONTRACT
        value = txFrame.fetchSlot(contractPath(c), slotPath(c, s)).expect("existing slot")
      checksum += value.truncate(uint64)
    of SlotMiss:
      let
        c = r mod CONTRACTS
        value = txFrame.fetchSlot(contractPath(c), missingSlotPath(r)).expect("existing account")
      doAssert value.isZero()
      inc checksum
    of BigSlotHit:
      let
        c = r mod BIG_CONTRACTS
        s = mix(r) mod BIG_SLOTS
        value = txFrame.fetchSlot(bigContractPath(c), bigSlotPath(c, s)).expect("existing slot")
      checksum += value.truncate(uint64)
    of BigSlotMiss:
      let
        c = r mod BIG_CONTRACTS
        value = txFrame.fetchSlot(bigContractPath(c), missingBigSlotPath(r)).expect("existing account")
      doAssert value.isZero()
      inc checksum
  ReadStats(
    usPerOp: (getMonoTime() - t0).inNanoseconds.float / 1e3 / READS.float,
    checksum: checksum,
  )

proc runWorkload(
    basePath: string, dbOpts: DbOptions, workload: Workload, direct: bool, leafLruSize: int
): (ReadStats, ReadStats) =
  let (db, _) = openAristoDb(basePath, dbOpts, wipe = false, direct, leafLruSize)
  let
    cold = db.runReads(workload, 0)
    warm = db.runReads(workload, 0)
  db.close()
  (cold, warm)

let
  dbOpts = makeDbOpts()
  dbDir = mkdtemp(dir = benchTmpDir)

try:
  echo &"building database: {ACCOUNTS} EOAs, {CONTRACTS} contracts x {SLOTS_PER_CONTRACT} slots, " &
    &"{BIG_CONTRACTS} contracts x {BIG_SLOTS} slots, index={BUILD_INDEX}, minimalCaches={MINIMAL_CACHES}"
  buildDb(dbDir, dbOpts)

  for leafLruSize in LEAF_LRU_SIZES:
    echo &"\nreads: {READS} per pass, leaf LRU {leafLruSize} entries, database reopened per workload"
    echo &"  {\"workload\":<14} {\"strategy\":<8} {\"cold us/op\":>11} {\"warm us/op\":>11}"
    for round in 1 .. ROUNDS:
      echo &"  round {round}"
      for workload in Workload:
        let (walkCold, walkWarm) =
          runWorkload(dbDir, dbOpts, workload, direct = false, leafLruSize)
        if not BUILD_INDEX:
          echo &"  {$workload:<14} {\"walk\":<8} {walkCold.usPerOp:>11.3f} {walkWarm.usPerOp:>11.3f}"
          continue
        let (directCold, directWarm) =
          runWorkload(dbDir, dbOpts, workload, direct = true, leafLruSize)
        doAssert walkCold.checksum == directCold.checksum and
          walkWarm.checksum == directWarm.checksum,
          "walk and direct fetch disagree on " & $workload
        echo &"  {$workload:<14} {\"walk\":<8} {walkCold.usPerOp:>11.3f} {walkWarm.usPerOp:>11.3f}"
        echo &"  {$workload:<14} {\"direct\":<8} {directCold.usPerOp:>11.3f} {directWarm.usPerOp:>11.3f}"
        echo &"  {\"\":<14} {\"speedup\":<8} {walkCold.usPerOp / directCold.usPerOp:>10.2f}x" &
          &" {walkWarm.usPerOp / directWarm.usPerOp:>10.2f}x"
finally:
  try:
    removeDir(benchTmpDir)
  except CatchableError:
    discard
