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
  std/[cpuinfo, monotimes, os, strformat, strutils, times],
  ../../execution_chain/db/aristo/[
    aristo_compute, aristo_merge, aristo_desc, aristo_init/memory_only,
    aristo_tx_frame,
  ]

const
  baseAccounts = 100_000
  accountsPerBlock = 200
  smallContracts = 128
  smallContractSlots = 4096
  largeContract = smallContracts
  largeContractSlots = 500_000
  blocks = 40
  warmupBlocks = 10

type
  Scenario = object
    name: string
    contracts: int
    slotsPerContract: int
    largeContractWrites: int

  Bench = object
    db: AristoDbRef
    tx: AristoTxRef
    blk: uint64
    accounts: uint64
    rng: uint64
    root: Hash32

const scenarios = [
  Scenario(name: "128 small x 1 slot", contracts: 128, slotsPerContract: 1),
  Scenario(name: "128 small x 2 slots", contracts: 128, slotsPerContract: 2),
  Scenario(name: "128 small x 4 slots", contracts: 128, slotsPerContract: 4),
  Scenario(name: "128 small x 16 slots", contracts: 128, slotsPerContract: 16),
  Scenario(name: "16 small x 2 slots", contracts: 16, slotsPerContract: 2),
  Scenario(name: "large x 5000 slots", largeContractWrites: 5000),
  Scenario(
    name: "large x 5000 slots + 128 small x 4 slots",
    contracts: 128,
    slotsPerContract: 4,
    largeContractWrites: 5000,
  ),
]

let numThreads = parseInt(getEnv("THREADS", $countProcessors()))

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

proc accPath(contract: int): Hash32 =
  path(uint64.high - uint64(contract))

proc slotPath(contract, slot: int): Hash32 =
  path((uint64(contract + 1) shl 40) + uint64(slot))

proc rand(b: var Bench, n: int): int =
  b.rng += 0x9E3779B97F4A7C15'u64
  int(mix(b.rng) mod uint64(n))

proc addAccounts(b: var Bench, n: int) =
  for _ in 0 ..< n:
    doAssert b.tx
      .mergeAccount(
        path(b.accounts),
        AristoAccount(balance: (b.accounts + b.blk).u256, codeHash: EMPTY_CODE_HASH),
        false,
      )
      .isOk()
    inc b.accounts

proc addContract(b: var Bench, contract, slots: int) =
  doAssert b.tx
    .mergeAccount(accPath(contract), AristoAccount(codeHash: EMPTY_CODE_HASH), false)
    .isOk()
  for slot in 0 ..< slots:
    doAssert b.tx.mergeSlot(accPath(contract), slotPath(contract, slot), 1.u256).isOk()

proc writeSlots(b: var Bench, contract, slots, count: int) =
  for _ in 0 ..< count:
    doAssert b.tx
      .mergeSlot(
        accPath(contract),
        slotPath(contract, b.rand(slots)),
        (b.blk * 1_000_000 + uint64(b.rand(1_000_000)) + 1).u256,
      )
      .isOk()

proc init(T: type Bench, parallel: bool): T =
  result.db = AristoDbRef.init()
  result.db.parallelStateRootComputation = false
  if parallel:
    result.db.taskpool = Taskpool.new(numThreads = numThreads)
  result.tx = result.db.txRef
  result.addAccounts(baseAccounts)
  for contract in 0 ..< smallContracts:
    result.addContract(contract, smallContractSlots)
  result.addContract(largeContract, largeContractSlots)
  doAssert result.tx.computeStateRoot().isOk()
  result.tx.checkpoint(1, skipSnapshot = true)
  let batch = result.db.putBegFn()[]
  result.db.persist(batch, result.tx)
  doAssert result.db.putEndFn(batch).isOk()
  result.tx = result.db.baseTxFrame()
  result.blk = 1
  result.db.parallelStateRootComputation = parallel

proc msPerBlock(b: var Bench, s: Scenario): float =
  var total = 0.0
  for i in 0 ..< blocks:
    b.tx = b.db.txFrameBegin(b.tx)
    inc b.blk
    b.addAccounts(accountsPerBlock)
    for contract in 0 ..< s.contracts:
      b.writeSlots(contract, smallContractSlots, s.slotsPerContract)
    b.writeSlots(largeContract, largeContractSlots, s.largeContractWrites)

    let start = getMonoTime()
    b.root = b.tx.computeStateRoot().expect("state root").to(Hash32)
    if i >= warmupBlocks:
      total += (getMonoTime() - start).inNanoseconds.float / 1e6
    b.tx.checkpoint(b.blk, skipSnapshot = false)
  total / float(blocks - warmupBlocks)

var
  results: array[bool, seq[float]]
  roots: array[bool, Hash32]

for parallel in [false, true]:
  var b = Bench.init(parallel)
  for s in scenarios:
    results[parallel].add b.msPerBlock(s)
  roots[parallel] = b.root
  if parallel:
    b.db.taskpool.shutdown()

doAssert roots[false] == roots[true], "serial and parallel roots differ"

echo &"threads: {numThreads}"
echo &"small contract: {smallContractSlots} slots"
echo &"large contract: {largeContractSlots} slots"
echo &"state root time per block, each block also adds {accountsPerBlock} accounts"
for i, s in scenarios:
  let
    serial = results[false][i]
    parallel = results[true][i]
  echo &"{s.name:<42} serial {serial:8.2f} ms | parallel {parallel:8.2f} ms" &
    &" | {serial / parallel:5.2f}x"
