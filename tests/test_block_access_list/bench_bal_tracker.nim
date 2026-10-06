# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Throughput benchmark for the BlockAccessListTracker, the component the EVM
# drives on every tracked state access. Each scenario models a block of
# transactions with a given call frame depth and a given mix of address
# accesses, storage reads and writes, balance and nonce changes per frame,
# with some frames reverting. The tracking cost (everything the EVM pays
# while executing) and the final list build are timed separately.

{.used.}

import
  std/[strformat, strutils, times],
  unittest2,
  stint,
  eth/common/addresses,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/core_db,
  ../../execution_chain/block_access_list/bal_tracker

type
  Workload = object
    name: string
    numTx: int
    numAccounts: int ## address space
    callDepth: int ## nested call frames below the transaction frame
    accessesPerFrame: int ## address accesses per frame
    readsPerFrame: int ## storage reads per frame
    writesPerFrame: int ## storage writes per frame
    revertEvery: int ## every n-th nested frame reverts, 0 for none

const
  benchNameWidth = 18
  repeats = 5
  scenarios = [
    # A plain value transfer: sender nonce and balance, recipient balance, the
    # coinbase fee, no calls.
    Workload(
      name: "transfer",
      numTx: 2048,
      numAccounts: 4000,
      callDepth: 0,
      accessesPerFrame: 1,
      readsPerFrame: 0,
      writesPerFrame: 0,
      revertEvery: 0,
    ),
    # A token transfer: one call into the token contract reading and writing a
    # few slots.
    Workload(
      name: "erc20",
      numTx: 2048,
      numAccounts: 4000,
      callDepth: 1,
      accessesPerFrame: 2,
      readsPerFrame: 3,
      writesPerFrame: 2,
      revertEvery: 0,
    ),
    # A DeFi interaction: several nested calls each touching other contracts
    # and reading more than they write.
    Workload(
      name: "defi call",
      numTx: 1024,
      numAccounts: 4000,
      callDepth: 4,
      accessesPerFrame: 5,
      readsPerFrame: 10,
      writesPerFrame: 3,
      revertEvery: 0,
    ),
    # Like the DeFi call but every other nested frame reverts, turning its
    # writes into reads.
    Workload(
      name: "reverting calls",
      numTx: 1024,
      numAccounts: 4000,
      callDepth: 4,
      accessesPerFrame: 5,
      readsPerFrame: 10,
      writesPerFrame: 3,
      revertEvery: 2,
    ),
    # A storage-heavy contract call.
    Workload(
      name: "storage heavy",
      numTx: 512,
      numAccounts: 4000,
      callDepth: 1,
      accessesPerFrame: 3,
      readsPerFrame: 50,
      writesPerFrame: 30,
      revertEvery: 0,
    ),
  ]

type
  Stats = object
    track: float ## average wall-clock of tracking a block (seconds)
    build: float ## average wall-clock of building the list (seconds)
    ops: int ## tracker calls per block
    checksum: int

func makeAddress(i: int): Address =
  var b: array[20, byte]
  for k in 0 ..< 8:
    b[19 - k] = byte((uint(i) shr (8 * k)) and 0xff)
  b.to(Address)

proc runTx(tracker: BlockAccessListTrackerRef, w: Workload, tx: int, ops: var int) =
  let
    sender = makeAddress(tx mod w.numAccounts)
    recipient = makeAddress((tx * 7 + 1) mod w.numAccounts)
    coinbase = makeAddress(w.numAccounts)
    fee = u256(21000 * 7)
    value = u256(tx + 1)

  tracker.setBlockAccessIndex(tx + 1)
  tracker.beginCallFrame()
  tracker.trackIncNonceChange(sender)
  tracker.trackSubBalanceChange(sender, fee)
  tracker.trackAddressAccess(recipient)
  tracker.trackSubBalanceChange(sender, value)
  tracker.trackAddBalanceChange(recipient, value)
  ops += 5

  template frameBody(depth: int) =
    let contract = makeAddress((tx * 13 + depth * 101 + 7) mod w.numAccounts)
    for k in 0 ..< w.accessesPerFrame:
      tracker.trackAddressAccess(makeAddress((tx * 3 + depth * 11 + k * 17) mod w.numAccounts))
    for k in 0 ..< w.readsPerFrame:
      tracker.trackStorageRead(contract, u256(depth * 100 + k))
    for k in 0 ..< w.writesPerFrame:
      # The SSTORE handler reads the current value for its gas calculation
      # before tracking the write, and passes it on when the tracker takes it.
      let
        slot = u256(depth * 100 + k)
        current = tracker.ledger.getStorage(contract, slot)
        newValue = u256(tx * 31 + k + 1)
      when compiles(tracker.trackStorageWrite(contract, slot, newValue, current)):
        tracker.trackStorageWrite(contract, slot, newValue, current)
      else:
        tracker.trackStorageWrite(contract, slot, newValue)
    ops += w.accessesPerFrame + w.readsPerFrame + w.writesPerFrame

  frameBody(0)
  for depth in 1 .. w.callDepth:
    tracker.beginCallFrame()
    frameBody(depth)
    ops += 2
  for depth in countdown(w.callDepth, 1):
    if w.revertEvery > 0 and (tx + depth) mod w.revertEvery == 0:
      tracker.rollbackCallFrame()
    else:
      tracker.commitCallFrame()

  tracker.trackAddBalanceChange(coinbase, fee)
  tracker.commitCallFrame()
  ops += 2

proc benchScenario(w: Workload): Stats =
  let
    coreDb = newCoreDbRef(DefaultDbMemory)
    ledger = LedgerRef.init(coreDb.baseTxFrame())
  for i in 0 .. w.numAccounts:
    let a = makeAddress(i)
    ledger.setBalance(a, u256(1_000_000 + i))
    ledger.setNonce(a, AccountNonce(i))
  for depth in 0 .. w.callDepth:
    for tx in 0 ..< w.numTx:
      let contract = makeAddress((tx * 13 + depth * 101 + 7) mod w.numAccounts)
      for k in 0 ..< max(w.readsPerFrame, w.writesPerFrame):
        ledger.setStorage(contract, u256(depth * 100 + k), u256(k + 1))

  var trackTotal, buildTotal = 0.0
  var checksum, ops = 0
  for r in 0 ..< repeats:
    let tracker = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger)
    tracker.builder[].ensureIndexCount(w.numTx + 2, exact = true)
    ops = 0
    let t0 = epochTime()
    for tx in 0 ..< w.numTx:
      tracker.runTx(w, tx, ops)
    let t1 = epochTime()
    let bal = tracker.getBlockAccessList(rebuild = true).get()
    let t2 = epochTime()
    trackTotal += t1 - t0
    buildTotal += t2 - t1
    checksum += bal[].len()
    tracker.dispose()
  Stats(
    track: trackTotal / repeats.float,
    build: buildTotal / repeats.float,
    ops: ops,
    checksum: checksum,
  )

proc describe(w: Workload): string =
  "txs=" & $w.numTx & ", depth=" & $w.callDepth & ", accesses/frame=" &
    $w.accessesPerFrame & ", reads/frame=" & $w.readsPerFrame & ", writes/frame=" &
    $w.writesPerFrame & ", revert every=" & $w.revertEvery & ", repeats=" & $repeats

suite "BlockAccessListTracker throughput benchmark":
  debugEcho ""
  debugEcho "  " & alignLeft("scenario", benchNameWidth) & " " & align("track(ms)", 10) &
    " " & align("build(ms)", 10) & " " & align("us/tx", 8) & " " & align("ns/op", 8)
  for w in scenarios:
    test w.name:
      let s = benchScenario(w)
      debugEcho "  " & alignLeft(w.name, benchNameWidth) & " " &
        align(fmt"{s.track * 1000:.2f}", 10) & " " & align(fmt"{s.build * 1000:.2f}", 10) &
        " " & align(fmt"{s.track * 1e6 / w.numTx.float:.2f}", 8) & " " &
        align(fmt"{s.track * 1e9 / s.ops.float:.1f}", 8) & "   " & w.describe()
      check s.checksum > 0
