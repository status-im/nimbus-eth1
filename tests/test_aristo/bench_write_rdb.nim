import
  std/[algorithm, monotimes, os, strformat, strutils, times],
  tempfile,
  results,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[
    aristo_compute, aristo_desc, aristo_merge, aristo_tx_frame],
  ../../execution_chain/db/aristo/aristo_init/[init_common, rocks_db],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc],
  rocksdb/lib/librocksdb

proc rocksdb_property_value_cf(
    db: RocksDbPtr, cf: ColFamilyHandlePtr, propname: cstring): cstring {.importc, cdecl.}

proc rocksdb_options_statistics_get_string(opts: DbOptionsPtr): cstring {.importc, cdecl.}

var statsOpts: DbOptionsRef

proc cfStats(baseDb: RocksDbInstanceRef, label: string) =
  let cf = baseDb.db.getColFamilyHandle($VtxCF).expect("cf")
  for prop in ["rocksdb.cfstats-no-file-histogram", "rocksdb.aggregated-table-properties-at-level0",
      "rocksdb.aggregated-table-properties-at-level6"]:
    let p = rocksdb_property_value_cf(baseDb.db.cPtr, cf.cPtr, prop.cstring)
    echo &"{label}: --- {prop}"
    echo $p
    rocksdb_free(p)
  if statsOpts != nil:
    let st = rocksdb_options_statistics_get_string(statsOpts.cPtr)
    echo &"{label}: --- rocksdb statistics"
    echo $st
    rocksdb_free(st)

const
  BASE_ACCOUNTS = 2_000_000
  BASE_CONTRACTS = 100_000
  SLOTS_PER_CONTRACT = 16
  BASE_LEAVES_PER_BLOCK = 100_000

  BLOCKS = 60
  WARMUP = 10
  ACC_UPDATES = 300
  ACC_NEW = 50
  SLOT_UPDATES = 700

let benchTmpDir = mkdtemp(prefix = "bench_write_", dir = getEnv("BENCH_DIR", getAppDir()))

proc makeDbOpts(): DbOptions =
  DbOptions.init(
    maxOpenFiles = 512, writeBufferSize = 64 * 1024 * 1024, rowCacheSize = 0,
    blockCacheSize = 256 * 1024 * 1024, rdbVtxCacheSize = 64 * 1024 * 1024,
    rdbKeyCacheSize = 128 * 1024 * 1024, rdbBranchCacheSize = 64 * 1024 * 1024,
    maxSnapshots = 2, parallelStateRootComputation = false, threadSafeCaches = false,
  )

proc openDb(basePath: string, wipe: bool): (AristoDbRef, RocksDbInstanceRef) =
  let
    dbOpts = makeDbOpts()
    cache = cacheCreateLRU(dbOpts.blockCacheSize, autoClose = true)
    rdbOpts = dbOpts.toDbOpts()
  when defined(RDB_STATS):
    rdbOpts.enableStatistics()
    statsOpts = rdbOpts
  let
    baseDb = RocksDbInstanceRef
      .open(basePath, rdbOpts, @[($VtxCF, dbOpts.toCfOpts(cache, true))], wipe)
      .expect("open")
    db = rocksDbBackend(dbOpts, baseDb)
  db.initInstance(
    dbOpts.maxSnapshots, false, threadSafeCaches = false,
    accLeavesLruSize = 1024 * 1024, stoLeavesLruSize = 1024 * 1024,
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

template contractPath(c: uint64): Hash32 = path(c)
template eoaPath(i: uint64): Hash32 = path(1_000_000_000'u64 + i)
template slotPath(c, s: uint64): Hash32 =
  path(2_000_000_000'u64 + c * SLOTS_PER_CONTRACT + s)

proc ms(d: Duration): float = d.inNanoseconds.float / 1e6

proc dirSize(dir: string): int64 =
  for f in walkDirRec(dir):
    try:
      result += getFileSize(f)
    except OSError:
      discard

proc walSize(dir: string): int64 =
  for f in walkDirRec(dir):
    if f.endsWith(".log"):
      try:
        result += getFileSize(f)
      except OSError:
        discard

proc median(xs: var seq[float]): float =
  xs.sort()
  xs[xs.len div 2]

proc mean(xs: openArray[float]): float =
  var s = 0.0
  for x in xs: s += x
  s / xs.len.float

proc buildBase(db: AristoDbRef) =
  var
    txFrame = db.txFrameBegin(db.txRef)
    inBlock = 0
    blockNo = 1'u64

  template flush() =
    if inBlock >= BASE_LEAVES_PER_BLOCK:
      txFrame.checkpoint(blockNo, skipSnapshot = true)
      let batch = db.putBegFn()[]
      db.persist(batch, txFrame)
      doAssert db.putEndFn(batch).isOk()
      inc blockNo
      inBlock = 0
      txFrame = db.txFrameBegin(db.txRef)

  for i in 0'u64 ..< BASE_ACCOUNTS:
    doAssert txFrame.mergeAccount(
      eoaPath(i),
      AristoAccount(nonce: 1, balance: i.u256, codeHash: EMPTY_CODE_HASH)).isOk()
    inc inBlock
    flush()
  for c in 0'u64 ..< BASE_CONTRACTS:
    doAssert txFrame.mergeAccount(
      contractPath(c),
      AristoAccount(nonce: 1, balance: c.u256, codeHash: EMPTY_CODE_HASH)).isOk()
    inc inBlock
    for s in 0'u64 ..< SLOTS_PER_CONTRACT:
      doAssert txFrame.mergeSlot(contractPath(c), slotPath(c, s), (s + 1).u256).isOk()
      inc inBlock
    flush()

  txFrame.checkpoint(blockNo, skipSnapshot = true)
  let batch = db.putBegFn()[]
  db.persist(batch, txFrame)
  doAssert db.putEndFn(batch).isOk()
  doAssert db.txRef.computeStateRoot(skipLayers = false).isOk()
  let batch2 = db.putBegFn()[]
  db.persist(batch2, db.txRef)
  doAssert db.putEndFn(batch2).isOk()

when isMainModule:
  let
    label = paramStr(1)
    dbDir = mkdtemp(dir = benchTmpDir)

  try:
    block:
      let (db, baseDb) = openDb(dbDir, wipe = true)
      let t0 = getMonoTime()
      db.buildBase()
      echo &"{label}: base build {ms(getMonoTime() - t0) / 1000:.1f} s, " &
        &"{dirSize(dbDir) div (1024 * 1024)} MiB"
      when defined(BASE_STATS):
        baseDb.cfStats(label & " base")
      db.close()

    let (db, baseDb) = openDb(dbDir, wipe = false)
    let sizeBefore = dirSize(dbDir)
    var
      mergeTimes, rootTimes, persistTimes: seq[float]
      ckptTimes, begTimes, loopTimes, commitTimes, vtxCounts, snapCounts: seq[float]
      walDeltas: seq[float]
      walPrev = walSize(dbDir)
      nextNew = BASE_ACCOUNTS.uint64

    for blk in 1 .. BLOCKS:
      let txFrame = db.txFrameBegin(db.txRef)
      let t0 = getMonoTime()
      for i in 0 ..< ACC_UPDATES:
        let a = mix(uint64(blk * 1_000_003 + i)) mod BASE_ACCOUNTS
        doAssert txFrame.mergeAccount(
          eoaPath(a),
          AristoAccount(
            nonce: uint64(blk + 2), balance: (a + blk.uint64).u256,
            codeHash: EMPTY_CODE_HASH)).isOk()
      for i in 0 ..< ACC_NEW:
        doAssert txFrame.mergeAccount(
          eoaPath(nextNew),
          AristoAccount(nonce: 1, balance: 1.u256, codeHash: EMPTY_CODE_HASH)).isOk()
        inc nextNew
      for i in 0 ..< SLOT_UPDATES:
        let
          r = mix(uint64(blk * 7_654_321 + i))
          c = r mod BASE_CONTRACTS
          s = (r shr 20) mod SLOTS_PER_CONTRACT
        doAssert txFrame.mergeSlot(
          contractPath(c), slotPath(c, s), (blk.uint64 + s + 2).u256).isOk()
      let t1 = getMonoTime()
      doAssert txFrame.computeStateRoot(skipLayers = false).isOk()
      let t2 = getMonoTime()
      let nVtx = txFrame.sTab.len
      txFrame.checkpoint(uint64(1_000_000 + blk), skipSnapshot = false)
      let t2a = getMonoTime()
      let nSnap = txFrame.snapshot.vtx.len
      let batch = db.putBegFn()[]
      let t2b = getMonoTime()
      db.persist(batch, txFrame)
      let t2c = getMonoTime()
      doAssert db.putEndFn(batch).isOk()
      let t3 = getMonoTime()

      if blk > WARMUP:
        mergeTimes.add ms(t1 - t0)
        rootTimes.add ms(t2 - t1)
        persistTimes.add ms(t3 - t2)
        ckptTimes.add ms(t2a - t2)
        begTimes.add ms(t2b - t2a)
        loopTimes.add ms(t2c - t2b)
        commitTimes.add ms(t3 - t2c)
        vtxCounts.add nVtx.float
        snapCounts.add nSnap.float
      let walNow = walSize(dbDir)
      if blk > WARMUP and walNow >= walPrev:
        walDeltas.add (walNow - walPrev).float
      walPrev = walNow

    let sizeAfter = dirSize(dbDir)
    baseDb.cfStats(label)
    db.close()

    let
      measured = BLOCKS - WARMUP
      grew = sizeAfter - sizeBefore
      leavesPerBlock = ACC_UPDATES + ACC_NEW + SLOT_UPDATES
    echo &"{label}: blocks {measured} x {leavesPerBlock} leaf writes"
    echo &"{label}: merge      mean {mean(mergeTimes):7.2f} ms | median {median(mergeTimes):7.2f} ms"
    echo &"{label}: state root mean {mean(rootTimes):7.2f} ms | median {median(rootTimes):7.2f} ms"
    echo &"{label}: persist    mean {mean(persistTimes):7.2f} ms | median {median(persistTimes):7.2f} ms"
    echo &"{label}: total/block     {mean(mergeTimes) + mean(rootTimes) + mean(persistTimes):7.2f} ms"
    echo &"{label}: persist split   ckpt {mean(ckptTimes):6.2f} | beg {mean(begTimes):6.2f} | " &
      &"loop {mean(loopTimes):6.2f} | commit {mean(commitTimes):6.2f} ms | " &
      &"vtx/block sTab {mean(vtxCounts):.0f} snapshot {mean(snapCounts):.0f}"
    echo &"{label}: wal bytes/block {mean(walDeltas):.0f} = {mean(walDeltas) / mean(vtxCounts):.1f} bytes/vertex ({walDeltas.len} samples)"
    echo &"{label}: db grew {grew div 1024} KiB over {BLOCKS} blocks" &
      &" = {grew div BLOCKS} bytes/block" &
      &" = {(grew.float / BLOCKS.float / leavesPerBlock.float):.1f} bytes/leaf write"
  finally:
    try:
      removeDir(benchTmpDir)
    except CatchableError:
      discard
