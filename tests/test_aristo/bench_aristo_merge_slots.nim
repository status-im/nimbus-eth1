# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/[algorithm, strformat, strutils, times],
  unittest2,
  stew/endians2,
  results,
  eth/common/hashes,
  ../../execution_chain/db/aristo/[
    aristo_compute,
    aristo_delete,
    aristo_desc,
    aristo_merge,
    aristo_tx_frame,
    aristo_init/init_common,
    aristo_init/memory_only,
  ]

const
  benchmarkNameWidth = 34
  accountCount {.intdefine.} = 500_000
  storageAccountCount {.intdefine.} = 5_000
  rounds = 4
  slotCounts = [1, 2, 4, 8]
  maxSlotsPerAccount = slotCounts[^1]
  deleteStride = 2

type BenchmarkStats = object
  elapsed: float
  operations: int

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchmarkNameWidth) & " " & align("elapsed(s)", 10) &
    " " & align("writes/s", 14) & " " & align("us/write", 10)

proc benchmarkLine(name: string, stats: BenchmarkStats): string =
  let
    writesPerSecond = stats.operations.float / stats.elapsed
    microsecondsPerWrite = (stats.elapsed * 1_000_000.0) / stats.operations.float
  "  " & alignLeft(name, benchmarkNameWidth) & " " & align(fmt"{stats.elapsed:.4f}", 10) &
    " " & align(fmt"{writesPerSecond:.2f}", 14) & " " &
    align(fmt"{microsecondsPerWrite:.4f}", 10)

func cmpSlotKey(a, b: Hash32): int =
  for i in 0 ..< a.data.len:
    if a.data[i] != b.data[i]:
      return cmp(a.data[i], b.data[i])
  0

proc makeAccPath(i: int): Hash32 =
  var seed {.noinit.}: array[8, byte]
  seed = uint64(i + 1).toBytesBE()
  keccak256(seed)

proc makeStoPath(acc, slot: int): Hash32 =
  var seed {.noinit.}: array[16, byte]
  seed[0 .. 7] = uint64(acc + 1).toBytesBE()
  seed[8 .. 15] = uint64(slot + 1).toBytesBE()
  keccak256(seed)

proc slotValue(acc, slot, round: int): UInt256 =
  (uint64(acc + 1) * 1_000_003'u64 + uint64(slot + 1) * 97'u64 + uint64(round + 1)).u256

proc seedDb(slotsPerAccount: int, accPaths: var seq[Hash32]): AristoDbRef =
  let db = AristoDbRef.init()
  db.parallelStateRootComputation = false

  accPaths.setLen(storageAccountCount)

  let wtx = db.txFrameBegin(db.baseTxFrame())
  for i in 0 ..< accountCount:
    let accPath = makeAccPath(i)
    doAssert wtx.mergeAccount(
      accPath, AristoAccount(balance: (i + 1).u256, codeHash: EMPTY_CODE_HASH)
    ).isOk()
    if i < storageAccountCount:
      accPaths[i] = accPath
      for s in 0 ..< slotsPerAccount:
        doAssert wtx.mergeSlot(accPath, makeStoPath(i, s), slotValue(i, s, 0)).isOk()

  wtx.checkpoint(1, skipSnapshot = true)
  let batch = db.putBegFn().expect("working batch")
  db.persist(batch, wtx)
  doAssert db.putEndFn(batch).isOk()

  db

proc mergePerSlot(
    tx: AristoTxRef, accPaths: openArray[Hash32], slotsPerAccount: int
): BenchmarkStats =
  let started = epochTime()
  for round in 1 .. rounds:
    for i in 0 ..< accPaths.len:
      for s in 0 ..< slotsPerAccount:
        doAssert tx.mergeSlot(accPaths[i], makeStoPath(i, s), slotValue(i, s, round)).isOk()
  BenchmarkStats(
    elapsed: epochTime() - started,
    operations: rounds * accPaths.len * slotsPerAccount,
  )

proc mergeBatched(
    tx: AristoTxRef, accPaths: openArray[Hash32], slotsPerAccount: int
): BenchmarkStats =
  var slots = newSeq[(Hash32, UInt256)](maxSlotsPerAccount)
  let started = epochTime()
  for round in 1 .. rounds:
    for i in 0 ..< accPaths.len:
      slots.setLen(slotsPerAccount)
      for s in 0 ..< slotsPerAccount:
        slots[s] = (makeStoPath(i, s), slotValue(i, s, round))
      slots.sort do (a, b: (Hash32, UInt256)) -> int:
        cmpSlotKey(a[0], b[0])
      doAssert tx.mergeSlots(accPaths[i], slots).isOk()
  BenchmarkStats(
    elapsed: epochTime() - started,
    operations: rounds * accPaths.len * slotsPerAccount,
  )

iterator deletedSlots(slotsPerAccount: int): int =
  # A subset so that the surviving slots keep the merged trie in the final
  # state root and the account keeps its storage trie registered
  for s in countup(0, slotsPerAccount - 1, deleteStride):
    yield s

proc deleteCount(slotsPerAccount: int): int =
  for _ in deletedSlots(slotsPerAccount):
    inc result

proc deletePerSlot(
    tx: AristoTxRef, accPaths: openArray[Hash32], slotsPerAccount: int
): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< accPaths.len:
    for s in deletedSlots(slotsPerAccount):
      doAssert tx.deleteSlot(accPaths[i], makeStoPath(i, s)).isOk()
  BenchmarkStats(
    elapsed: epochTime() - started,
    operations: accPaths.len * deleteCount(slotsPerAccount),
  )

proc deleteBatched(
    tx: AristoTxRef, accPaths: openArray[Hash32], slotsPerAccount: int
): BenchmarkStats =
  var slots = newSeqOfCap[Hash32](maxSlotsPerAccount)
  let started = epochTime()
  for i in 0 ..< accPaths.len:
    slots.setLen(0)
    for s in deletedSlots(slotsPerAccount):
      slots.add(makeStoPath(i, s))
    slots.sort(cmpSlotKey)
    doAssert tx.deleteSlots(accPaths[i], slots).isOk()
  BenchmarkStats(
    elapsed: epochTime() - started,
    operations: accPaths.len * deleteCount(slotsPerAccount),
  )

suite "Aristo storage merge benchmark":
  test "Benchmark mergeSlot/deleteSlot per slot vs batched":
    debugEcho ""
    debugEcho "Aristo storage merge benchmark"
    debugEcho "  accounts seeded: ", accountCount, ", with storage: ",
      storageAccountCount, ", rounds: ", rounds
    debugEcho benchmarkHeader()

    for slotsPerAccount in slotCounts:
      var accPaths: seq[Hash32]
      let db = seedDb(slotsPerAccount, accPaths)

      # Warm the db-level leaf caches on a throwaway frame first. Without this
      # whichever variant runs second wins on cache state alone, which at
      # 500k accounts is worth more than the difference being measured.
      # Nothing here may compute a state root either - that writes keys back
      # through the backend and would leave the next run on different footing.
      let warmupTx = db.txFrameBegin(db.baseTxFrame())
      discard mergePerSlot(warmupTx, accPaths, slotsPerAccount)
      warmupTx.dispose()

      # Batched runs first so any residual ordering bias counts against it
      let
        batchedTx = db.txFrameBegin(db.baseTxFrame())
        batchedMerge = mergeBatched(batchedTx, accPaths, slotsPerAccount)
        batchedDelete = deleteBatched(batchedTx, accPaths, slotsPerAccount)
        perSlotTx = db.txFrameBegin(db.baseTxFrame())
        perSlotMerge = mergePerSlot(perSlotTx, accPaths, slotsPerAccount)
        perSlotDelete = deletePerSlot(perSlotTx, accPaths, slotsPerAccount)

      check batchedTx.computeStateRoot().expect("batched state root") ==
        perSlotTx.computeStateRoot().expect("per-slot state root")

      debugEcho benchmarkLine(
        fmt"mergeSlot    ({slotsPerAccount} slots/acc)", perSlotMerge)
      debugEcho benchmarkLine(
        fmt"mergeSlots   ({slotsPerAccount} slots/acc)", batchedMerge)
      debugEcho fmt"  -> speedup {perSlotMerge.elapsed / batchedMerge.elapsed:.2f}x"
      debugEcho benchmarkLine(
        fmt"deleteSlot   ({slotsPerAccount} slots/acc)", perSlotDelete)
      debugEcho benchmarkLine(
        fmt"deleteSlots  ({slotsPerAccount} slots/acc)", batchedDelete)
      debugEcho fmt"  -> speedup {perSlotDelete.elapsed / batchedDelete.elapsed:.2f}x"

      perSlotTx.dispose()
      batchedTx.dispose()
      db.close()
