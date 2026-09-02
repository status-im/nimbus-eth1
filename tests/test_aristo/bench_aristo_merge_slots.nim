# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Benchmark for the storage write path in `aristo_merge`.
##
## `mergeSlot` resolves the account leaf with a full hike from the state root
## and invalidates the Merkle keys along that path for every single slot.
## `mergeSlots` does both once for all the slots of one account, which is how
## the ledger writes them (`persistStorage` groups the dirty slots per account).
##
## The benchmark seeds an account trie with storage, persists it to an in-memory
## backend and then re-writes the same slots through both APIs, checking that
## the resulting state roots agree.

{.used.}

import
  std/[strformat, strutils, times],
  unittest2,
  stew/endians2,
  results,
  eth/common/hashes,
  ../../execution_chain/db/aristo/[
    aristo_compute,
    aristo_desc,
    aristo_merge,
    aristo_tx_frame,
    aristo_init/init_common,
    aristo_init/memory_only,
  ]

const
  benchmarkNameWidth = 30
  accountCount {.intdefine.} = 500_000
    ## Accounts seeded into the state trie. This only sets the depth of the
    ## account hike that `mergeSlot` repeats per slot and `mergeSlots` does
    ## once, but that depth is the whole point - a small trie is shallow and
    ## hides the win (log16(10k) is ~3 levels against ~7 on mainnet).
  storageAccountCount {.intdefine.} = 5_000
    ## Of those, the accounts that get storage and are then benchmarked
  rounds = 4
  slotCounts = [1, 2, 4, 8]
  maxSlotsPerAccount = slotCounts[^1]

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

proc makeAccPath(i: int): Hash32 =
  ## Hashed so the seeded accounts spread evenly over the trie and the hikes
  ## reach a realistic depth
  var seed {.noinit.}: array[8, byte]
  seed = uint64(i + 1).toBytesBE()
  keccak256(seed)

proc makeStoPath(acc, slot: int): Hash32 =
  var seed {.noinit.}: array[16, byte]
  seed[0 .. 7] = uint64(acc + 1).toBytesBE()
  seed[8 .. 15] = uint64(slot + 1).toBytesBE()
  keccak256(seed)

proc slotValue(acc, slot, round: int): UInt256 =
  # A fresh value every round so the merge never short-circuits on MergeNoAction
  (uint64(acc + 1) * 1_000_003'u64 + uint64(slot + 1) * 97'u64 + uint64(round + 1)).u256

proc seedDb(slotsPerAccount: int, accPaths: var seq[Hash32]): AristoDbRef =
  ## Populate `accountCount` accounts so the account trie has a realistic
  ## depth, give the first `storageAccountCount` of them `slotsPerAccount`
  ## storage slots, and persist everything to the backend so the benchmarked
  ## writes start from a cold set of layers.
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

proc runPerSlot(
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

proc runBatched(
    tx: AristoTxRef, accPaths: openArray[Hash32], slotsPerAccount: int
): BenchmarkStats =
  # The ledger reuses one scratch buffer for this, so do the same here
  var slots = newSeq[(Hash32, UInt256)](maxSlotsPerAccount)
  let started = epochTime()
  for round in 1 .. rounds:
    for i in 0 ..< accPaths.len:
      slots.setLen(slotsPerAccount)
      for s in 0 ..< slotsPerAccount:
        slots[s] = (makeStoPath(i, s), slotValue(i, s, round))
      doAssert tx.mergeSlots(accPaths[i], slots).isOk()
  BenchmarkStats(
    elapsed: epochTime() - started,
    operations: rounds * accPaths.len * slotsPerAccount,
  )

suite "Aristo storage merge benchmark":
  test "Benchmark mergeSlot per slot vs batched mergeSlots":
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
      discard runPerSlot(warmupTx, accPaths, slotsPerAccount)
      warmupTx.dispose()

      # Batched runs first so any residual ordering bias counts against it
      let
        batchedTx = db.txFrameBegin(db.baseTxFrame())
        batched = runBatched(batchedTx, accPaths, slotsPerAccount)
        perSlotTx = db.txFrameBegin(db.baseTxFrame())
        perSlot = runPerSlot(perSlotTx, accPaths, slotsPerAccount)

      # Both paths must produce exactly the same trie
      check batchedTx.computeStateRoot().expect("batched state root") ==
        perSlotTx.computeStateRoot().expect("per-slot state root")

      let speedup = perSlot.elapsed / batched.elapsed
      debugEcho benchmarkLine(fmt"mergeSlot   ({slotsPerAccount} slots/acc)", perSlot)
      debugEcho benchmarkLine(fmt"mergeSlots  ({slotsPerAccount} slots/acc)", batched)
      debugEcho fmt"  -> speedup {speedup:.2f}x"

      perSlotTx.dispose()
      batchedTx.dispose()
      db.close()
