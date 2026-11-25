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
  std/[algorithm, cpuinfo, monotimes, os, strformat, strutils, times],
  ../../execution_chain/db/aristo/[
    aristo_compute, aristo_merge, aristo_desc, aristo_init/memory_only,
    aristo_tx_frame,
  ]

const
  baseAccounts = 100_000
  deepContracts = 128
  deepSlots = 4096
  giantSlots = 500_000
  warmup = 10

let
  numThreads = parseInt(getEnv("THREADS", $countProcessors()))
  only = getEnv("SCENARIO", "")

type
  Bench = object
    db: AristoDbRef
    tx: AristoTxRef
    blk: uint64
    accounts: uint64
    rng: uint64
    root: Hash32

  Stats = tuple[mean, p50, p95, max: float]

  Scenario = object
    name: string
    blocks: int
    deep: int
    deepWrites: int
    giantWrites: int
    pending: int
    spinMs: int

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
  for contract in 0 .. deepContracts:
    doAssert result.tx
      .mergeAccount(accPath(contract), AristoAccount(codeHash: EMPTY_CODE_HASH), false)
      .isOk()
    let slots = if contract == deepContracts: giantSlots else: deepSlots
    for slot in 0 ..< slots:
      doAssert result.tx
        .mergeSlot(accPath(contract), slotPath(contract, slot), 1.u256)
        .isOk()
  doAssert result.tx.computeStateRoot(skipLayers = false).isOk()
  result.tx.checkpoint(1, skipSnapshot = true)
  let batch = result.db.putBegFn()[]
  result.db.persist(batch, result.tx)
  doAssert result.db.putEndFn(batch).isOk()
  result.tx = result.db.baseTxFrame()
  result.blk = 1
  result.db.parallelStateRootComputation = parallel

proc spin(ms: int): bool {.gcsafe, raises: [].} =
  let start = getMonoTime()
  var x = 0'u64
  while (getMonoTime() - start).inMilliseconds < ms:
    for i in 0 ..< 1000:
      x = mix(x + uint64(i))
  x != 0

proc stats(xs: seq[float]): Stats =
  var sorted = xs
  sorted.sort()
  var sum = 0.0
  for x in sorted:
    sum += x
  (sum / float(sorted.len), sorted[sorted.len div 2], sorted[sorted.len * 95 div 100],
    sorted[^1])

proc run(b: var Bench, s: Scenario): Stats =
  var times: seq[float]
  for _ in 0 ..< s.blocks:
    b.tx = b.db.txFrameBegin(b.tx)
    inc b.blk
    b.addAccounts(200)
    if s.deep == deepContracts:
      for contract in 0 ..< deepContracts:
        b.writeSlots(contract, deepSlots, s.deepWrites)
    else:
      for _ in 0 ..< s.deep:
        b.writeSlots(b.rand(deepContracts), deepSlots, s.deepWrites)
    if s.giantWrites > 0:
      b.writeSlots(deepContracts, giantSlots, s.giantWrites)

    var futs: seq[Flowvar[bool]]
    if not b.db.taskpool.isNil():
      for _ in 0 ..< s.pending:
        futs.add b.db.taskpool.spawn spin(s.spinMs)

    let t0 = getMonoTime()
    let res = b.tx.computeStateRoot(skipLayers = false)
    times.add (getMonoTime() - t0).inNanoseconds.float / 1e6
    doAssert res.isOk()
    b.root = res[].to(Hash32)

    for f in futs.mitems():
      discard sync(f)
    b.tx.checkpoint(b.blk, skipSnapshot = false)
  stats(times[warmup .. ^1])

let scenarios = [
  Scenario(name: "128 deep x 1 slot", blocks: 40, deep: 128, deepWrites: 1),
  Scenario(name: "128 deep x 2 slots", blocks: 40, deep: 128, deepWrites: 2),
  Scenario(name: "128 deep x 4 slots", blocks: 40, deep: 128, deepWrites: 4),
  Scenario(name: "128 deep x 16 slots", blocks: 40, deep: 128, deepWrites: 16),
  Scenario(name: "16 deep x 2 slots", blocks: 40, deep: 16, deepWrites: 2),
  Scenario(name: "giant 5000", blocks: 110, giantWrites: 5000),
  Scenario(
    name: "giant 5000 + 128 deep x 4", blocks: 110, deep: 128, deepWrites: 4,
    giantWrites: 5000,
  ),
  Scenario(
    name: "128 deep x 2, 8 pending 20ms", blocks: 40, deep: 128, deepWrites: 2,
    pending: 8, spinMs: 20,
  ),
  Scenario(
    name: "128 deep x 2, 2 pending 100ms", blocks: 40, deep: 128, deepWrites: 2,
    pending: 2, spinMs: 100,
  ),
  Scenario(
    name: "128 deep x 2, 32 pending 5ms", blocks: 40, deep: 128, deepWrites: 2,
    pending: 32, spinMs: 5,
  ),
]

var
  results: array[2, seq[Stats]]
  roots: array[2, Hash32]

for parallel in [false, true]:
  var b = Bench.init(parallel)
  for s in scenarios:
    if only.len == 0 or only in s.name:
      results[int(parallel)].add b.run(s)
  roots[int(parallel)] = b.root
  if parallel:
    b.db.taskpool.shutdown()

doAssert roots[0] == roots[1], "serial and parallel roots differ"

echo &"threads: {numThreads}"
var n = 0
for s in scenarios:
  if only.len == 0 or only in s.name:
    let
      serial = results[0][n]
      par = results[1][n]
    echo &"{s.name:<30} serial {serial.mean:8.2f} ms | parallel mean {par.mean:8.2f}" &
      &" p50 {par.p50:8.2f} p95 {par.p95:8.2f} max {par.max:8.2f}"
    inc n
