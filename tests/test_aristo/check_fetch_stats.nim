import
  std/[monotimes, os, strformat, times],
  tempfile,
  results,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_compute, aristo_desc, aristo_fetch, aristo_merge, aristo_tx_frame],
  ../../execution_chain/db/aristo/aristo_fetch_stats,
  ../../execution_chain/db/aristo/aristo_init/[init_common, rocks_db],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  EOAS = 20_000
  CONTRACTS = 2_000
  SLOTS_PER_CONTRACT = 64
  READS = 50_000

let tmpDir = mkdtemp(prefix = "check_fetch_stats_", dir = getAppDir())

proc openDb(basePath: string, wipe: bool, tinyCaches: bool): AristoDbRef =
  let
    mib = 1024 * 1024
    dbOpts = DbOptions.init(
      maxOpenFiles = 512, writeBufferSize = 16 * mib, rowCacheSize = 0,
      blockCacheSize = 64 * mib,
      rdbVtxCacheSize = (if tinyCaches: 1 else: 64) * mib,
      rdbKeyCacheSize = (if tinyCaches: 1 else: 64) * mib,
      rdbBranchCacheSize = (if tinyCaches: 1 else: 64) * mib,
      maxSnapshots = 2, parallelStateRootComputation = false,
      threadSafeCaches = false)
    cache = cacheCreateLRU(dbOpts.blockCacheSize, autoClose = true)
    baseDb = RocksDbInstanceRef
      .open(basePath, dbOpts.toDbOpts(), @[($VtxCF, dbOpts.toCfOpts(cache, true))], wipe)
      .expect("open")
    db = rocksDbBackend(dbOpts, baseDb)
  db.initInstance(
    dbOpts.maxSnapshots, false, threadSafeCaches = false,
    accLeavesLruSize = (if tinyCaches: 1 else: 4096),
    stoLeavesLruSize = (if tinyCaches: 1 else: 4096)).expect("aristo db")
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

template contractPath(c: uint64): Hash32 = path(c)
template eoaPath(i: uint64): Hash32 = path(1_000_000'u64 + i)
template slotPath(c, s: uint64): Hash32 = path(2_000_000'u64 + c * SLOTS_PER_CONTRACT + s)
template missingAccPath(i: uint64): Hash32 = path(500_000_000'u64 + i)
template missingSlotPath(i: uint64): Hash32 = path(900_000_000'u64 + i)

proc build(db: AristoDbRef) =
  let txFrame = db.txFrameBegin(db.txRef)
  for i in 0'u64 ..< EOAS:
    doAssert txFrame.mergeAccount(
      eoaPath(i), AristoAccount(nonce: 1, balance: i.u256, codeHash: EMPTY_CODE_HASH)).isOk()
  for c in 0'u64 ..< CONTRACTS:
    doAssert txFrame.mergeAccount(
      contractPath(c), AristoAccount(nonce: 1, balance: c.u256, codeHash: EMPTY_CODE_HASH)).isOk()
    for s in 0'u64 ..< SLOTS_PER_CONTRACT:
      doAssert txFrame.mergeSlot(contractPath(c), slotPath(c, s), (s + 1).u256).isOk()
  txFrame.checkpoint(1, skipSnapshot = true)
  let batch = db.putBegFn()[]
  db.persist(batch, txFrame)
  doAssert db.putEndFn(batch).isOk()
  doAssert db.txRef.computeStateRoot(skipLayers = false).isOk()
  let batch2 = db.putBegFn()[]
  db.persist(batch2, db.txRef)
  doAssert db.putEndFn(batch2).isOk()

proc runReads(db: AristoDbRef, label: string) =
  let tx = db.txRef
  var sum = 0'u64
  let t0 = getMonoTime()
  for i in 0'u64 ..< READS:
    let r = mix(i)
    sum += tx.fetchAccount(eoaPath(r mod EOAS)).expect("account").balance.truncate(uint64)
    doAssert tx.fetchAccount(missingAccPath(r)).isErr()
    sum += tx.fetchSlot(
      contractPath(r mod CONTRACTS), slotPath(r mod CONTRACTS, mix(r) mod SLOTS_PER_CONTRACT)
    ).expect("slot").truncate(uint64)
    doAssert tx.fetchSlot(contractPath(r mod CONTRACTS), missingSlotPath(r)).expect("miss").isZero()
  let us = (getMonoTime() - t0).inNanoseconds.float / 1e3 / (4 * READS).float
  echo &"{label}: {4 * READS} fetches, {us:.3f} us/fetch, statsEnabled={LeafFetchStats}, checksum {sum}"

when isMainModule:
  try:
    block:
      let db = openDb(tmpDir, wipe = true, tinyCaches = false)
      db.build()
      db.close()
    block:
      echo "--- cold reads, minimal in-process caches"
      let db = openDb(tmpDir, wipe = false, tinyCaches = true)
      db.runReads("tiny caches")
      db.close()
    block:
      echo "--- warm reads, production-size caches"
      let db = openDb(tmpDir, wipe = false, tinyCaches = false)
      db.runReads("large caches, cold")
      db.runReads("large caches, warm")
      db.close()
  finally:
    try:
      removeDir(tmpDir)
    except CatchableError:
      discard
