import
  std/[os, strformat],
  results,
  ../../execution_chain/db/opts,
  ../../execution_chain/db/aristo/[aristo_desc, aristo_fetch, aristo_merge, aristo_tx_frame],
  ../../execution_chain/db/aristo/aristo_init/[init_common, rocks_db],
  ../../execution_chain/db/core_db/backend/[aristo_rocksdb, rocksdb_desc]

const
  ACCOUNTS = 20_000
  CONTRACTS = 2_000
  SLOTS_PER_CONTRACT = 8

proc makeDbOpts(): DbOptions =
  DbOptions.init(
    maxOpenFiles = 512, writeBufferSize = 16 * 1024 * 1024, rowCacheSize = 0,
    blockCacheSize = 64 * 1024 * 1024, rdbVtxCacheSize = 16 * 1024 * 1024,
    rdbKeyCacheSize = 16 * 1024 * 1024, rdbBranchCacheSize = 16 * 1024 * 1024,
    maxSnapshots = 2, parallelStateRootComputation = false, threadSafeCaches = false,
  )

proc openDb(basePath: string, wipe: bool): AristoDbRef =
  let
    dbOpts = makeDbOpts()
    cache = cacheCreateLRU(dbOpts.blockCacheSize, autoClose = true)
    baseDb = RocksDbInstanceRef
      .open(basePath, dbOpts.toDbOpts(), @[($VtxCF, dbOpts.toCfOpts(cache, true))], wipe)
      .expect("open")
    db = rocksDbBackend(dbOpts, baseDb)
  db.initInstance(
    dbOpts.maxSnapshots, false, threadSafeCaches = false,
    accLeavesLruSize = 4096, stoLeavesLruSize = 4096,
  ).expect("aristo db")
  db

template legacyFlag(db: AristoDbRef): string =
  when compiles(db.legacyLeaves):
    $db.legacyLeaves
  else:
    "n/a"

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
template slotPath(c, s: uint64): Hash32 =
  path(2_000_000'u64 + c * SLOTS_PER_CONTRACT + s)
template missingPath(i: uint64): Hash32 = path(900_000_000'u64 + i)

template balanceOf(i: uint64): UInt256 = (i + 1).u256
template slotValue(c, s: uint64): UInt256 = (c * 100 + s + 1).u256

proc write(db: AristoDbRef, lo, hi: uint64, blockNo: uint64) =
  var txFrame = db.txFrameBegin(db.txRef)
  for i in lo ..< hi:
    doAssert txFrame.mergeAccount(
      eoaPath(i),
      AristoAccount(nonce: 1, balance: balanceOf(i), codeHash: EMPTY_CODE_HASH),
    ).isOk()
  for c in lo ..< min(hi, CONTRACTS):
    doAssert txFrame.mergeAccount(
      contractPath(c),
      AristoAccount(nonce: 1, balance: balanceOf(c), codeHash: EMPTY_CODE_HASH),
    ).isOk()
    for s in 0'u64 ..< SLOTS_PER_CONTRACT:
      doAssert txFrame.mergeSlot(contractPath(c), slotPath(c, s), slotValue(c, s)).isOk()
  txFrame.checkpoint(blockNo, skipSnapshot = true)
  let batch = db.putBegFn()[]
  db.persist(batch, txFrame)
  doAssert db.putEndFn(batch).isOk()

proc verify(db: AristoDbRef, hi: uint64): int =
  let tx = db.txRef
  var checked = 0
  for i in 0'u64 ..< hi:
    let acc = tx.fetchAccount(eoaPath(i)).valueOr:
      raiseAssert &"eoa {i} not found: {error}"
    doAssert acc.balance == balanceOf(i), &"eoa {i} wrong balance"
    inc checked
  for c in 0'u64 ..< min(hi, CONTRACTS):
    let acc = tx.fetchAccount(contractPath(c)).valueOr:
      raiseAssert &"contract {c} not found: {error}"
    doAssert acc.balance == balanceOf(c), &"contract {c} wrong balance"
    inc checked
    for s in 0'u64 ..< SLOTS_PER_CONTRACT:
      let v = tx.fetchSlot(contractPath(c), slotPath(c, s)).valueOr:
        raiseAssert &"slot {c}/{s} not found: {error}"
      doAssert v == slotValue(c, s), &"slot {c}/{s} wrong value {v}"
      inc checked
  for i in 0'u64 ..< 2000:
    let rc = tx.fetchAccount(missingPath(i))
    doAssert rc.isErr and rc.error == FetchPathNotFound,
      &"missing account {i} unexpectedly found"
    inc checked
  for c in 0'u64 ..< min(hi, 200):
    let v = tx.fetchSlot(contractPath(c), missingPath(500_000 + c)).valueOr:
      raiseAssert &"missing slot on contract {c}: {error}"
    doAssert v.isZero(), &"missing slot on contract {c} returned {v}"
    inc checked
  checked

when isMainModule:
  let
    mode = paramStr(1)
    dir = paramStr(2)
  case mode
  of "build":
    let db = openDb(dir, wipe = true)
    db.write(0, ACCOUNTS, 1)
    let n = db.verify(ACCOUNTS)
    db.close()
    echo &"build: wrote and verified {n} lookups"
  of "read":
    let db = openDb(dir, wipe = false)
    echo &"read: legacyLeaves={db.legacyFlag}"
    let n = db.verify(ACCOUNTS)
    db.close()
    echo &"read: verified {n} lookups"
  of "append":
    let db = openDb(dir, wipe = false)
    echo &"append: legacyLeaves={db.legacyFlag}"
    db.write(ACCOUNTS, ACCOUNTS * 2, 2)
    let n = db.verify(ACCOUNTS * 2)
    db.close()
    echo &"append: verified {n} lookups"
  else:
    raiseAssert "usage: compat_check build|read|append <dir>"
