# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Benchmark for the leaf-cache read path in `aristo_fetch` (`fetchAccount` /
## `fetchSlot`). Accounts and one storage slot each are merged and persisted to
## an in-memory backend, the leaf caches (`accLeaves`/`stoLeaves`) are warmed,
## and then the fetches are timed - so the measured loop is dominated by the
## `withGet`/`get` cache-hit path that `cachedAccLeaf`/`cachedStoLeaf`/`fetchSlot`
## use.

{.used.}

import
  std/[strformat, strutils, times],
  unittest2,
  stew/endians2,
  results,
  eth/common/hashes,
  ../../execution_chain/db/aristo/[
    aristo_desc,
    aristo_fetch,
    aristo_merge,
    aristo_tx_frame,
    aristo_init/init_common,
    aristo_init/memory_only,
  ]

const
  benchmarkNameWidth = 28
  accountCount = 20_000
  readCount = 5_000_000

type BenchmarkStats = object
  elapsed: float
  operations: int
  checksum: uint64

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchmarkNameWidth) & " " & align("elapsed(s)", 10) &
    " " & align("reads/s", 14) & " " & align("us/read", 10)

proc benchmarkLine(name: string, stats: BenchmarkStats): string =
  let
    readsPerSecond = stats.operations.float / stats.elapsed
    microsecondsPerRead = (stats.elapsed * 1_000_000.0) / stats.operations.float
  "  " & alignLeft(name, benchmarkNameWidth) & " " & align(fmt"{stats.elapsed:.4f}", 10) &
    " " & align(fmt"{readsPerSecond:.2f}", 14) & " " &
    align(fmt"{microsecondsPerRead:.4f}", 10)

proc makeAccPath(i: uint64): Hash32 =
  var path: Hash32
  path.data()[0 .. 7] = i.toBytesBE()
  path

const stoPath =
  hash32"2000000000000000000000000000000000000000000000000000000000000001"

proc makeReadOrder(sampleCount: int): seq[int] =
  result = newSeq[int](readCount)
  for i in 0 ..< readCount:
    result[i] = ((i.int64 * 2654435761'i64) mod sampleCount.int64).int

proc runFetchAccountBenchmark(
    tx: AristoTxRef, accPaths: openArray[Hash32], readOrder: openArray[int]
): BenchmarkStats =
  var checksum = 0'u64
  let started = epochTime()
  for index in readOrder:
    let acc = tx.fetchAccount(accPaths[index]).expect("benchmark fetchAccount")
    checksum += acc.balance.truncate(uint64)
  BenchmarkStats(
    elapsed: epochTime() - started, operations: readOrder.len, checksum: checksum
  )

proc runFetchSlotBenchmark(
    tx: AristoTxRef, accPaths: openArray[Hash32], readOrder: openArray[int]
): BenchmarkStats =
  var checksum = 0'u64
  let started = epochTime()
  for index in readOrder:
    let slot = tx.fetchSlot(accPaths[index], stoPath).expect("benchmark fetchSlot")
    checksum += slot.truncate(uint64)
  BenchmarkStats(
    elapsed: epochTime() - started, operations: readOrder.len, checksum: checksum
  )

suite "Aristo fetch leaf-cache benchmark":
  test "Benchmark fetchAccount and fetchSlot (warm leaf caches)":
    # Serial state-root computation so no taskpool is required for `persist`.
    let db = AristoDbRef.init()
    db.parallelStateRootComputation = false

    var accPaths = newSeq[Hash32](accountCount)

    # Populate accounts + one storage slot each and persist to the backend
    let wtx = db.txFrameBegin(db.baseTxFrame())
    for i in 0 ..< accountCount:
      let accPath = makeAccPath((i + 1).uint64)
      accPaths[i] = accPath
      check wtx.mergeAccount(
        accPath, AristoAccount(balance: (i + 1).u256, codeHash: EMPTY_CODE_HASH)
      ).isOk()
      check wtx.mergeSlot(accPath, stoPath, (i + 1).u256).isOk()

    wtx.checkpoint(1, skipSnapshot = true)
    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, wtx)
    check db.putEndFn(batch).isOk()

    # Re-open with fresh, cache-enabled instance so reads fall through the empty
    # layers into the leaf caches (backed by the persisted data).
    db.close()
    db.initInstance(
      accLeavesLruSize = ACC_LRU_SIZE,
      stoLeavesLruSize = ACC_LRU_SIZE,
      parallelStateRootComputation = false,
    ).expect("re-init instance")
    let tx = db.baseTxFrame()

    # Warm the leaf caches with one fetch per account/slot
    for accPath in accPaths:
      check tx.fetchAccount(accPath).isOk()
      check tx.fetchSlot(accPath, stoPath).isOk()

    # Sanity check that the reads are actually served by the leaf caches
    check:
      db.accLeaves.len == accountCount
      db.stoLeaves.len == accountCount

    let readOrder = makeReadOrder(accountCount)

    let
      fetchAccount = runFetchAccountBenchmark(tx, accPaths, readOrder)
      fetchSlot = runFetchSlotBenchmark(tx, accPaths, readOrder)

    debugEcho ""
    debugEcho "Aristo fetch leaf-cache benchmark"
    debugEcho "  accounts seeded: ", accountCount
    debugEcho "  accLeaves cached: ", db.accLeaves.len
    debugEcho "  stoLeaves cached: ", db.stoLeaves.len
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("fetchAccount warm cache", fetchAccount)
    debugEcho benchmarkLine("fetchSlot warm cache", fetchSlot)
    debugEcho "  checksum(fetchAccount): ", fetchAccount.checksum
    debugEcho "  checksum(fetchSlot): ", fetchSlot.checksum

    check:
      fetchAccount.checksum != 0
      fetchSlot.checksum != 0
