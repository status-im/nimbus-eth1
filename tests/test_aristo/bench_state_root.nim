# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

# Benchmarks serial vs parallel state root computation over realistic in-memory
# scenarios: steady-state block import, batch catch-up and flat bulk import.

import
  std/[algorithm, cpuinfo, monotimes, times, strformat],
  ../../execution_chain/db/aristo/[
    aristo_compute, aristo_merge, aristo_desc, aristo_init/memory_only,
    aristo_tx_frame,
  ]

let numThreads = countProcessors()

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

var pathCounter: uint64

proc addAccounts(txFrame: AristoTxRef, n: int) =
  for _ in 0 ..< n:
    let p = path(pathCounter)
    inc pathCounter
    doAssert txFrame.mergeAccount(
      p, AristoAccount(balance: pathCounter.u256(), codeHash: EMPTY_CODE_HASH)
    ).isOk()

proc newDb(baseAccounts: int): (AristoDbRef, AristoTxRef) =
  # Base state with computed keys, persisted to the (memory) backend so the
  # per-block scenarios start from a warm, realistic baseline.
  pathCounter = 0
  let db = AristoDbRef.init()
  db.taskpool = Taskpool.new(numThreads = numThreads)
  db.parallelStateRootComputation = false
  var txFrame = db.txRef
  txFrame.addAccounts(baseAccounts)
  doAssert txFrame.computeStateRoot(skipLayers = false).isOk()
  txFrame.checkpoint(1, skipSnapshot = true)
  let batch = db.putBegFn()[]
  db.persist(batch, txFrame)
  doAssert db.putEndFn(batch).isOk()
  (db, db.baseTxFrame())

proc ms(d: Duration): float =
  d.inNanoseconds.float / 1e6

# Steady-state import: root computed for every block, snapshot per block as in
# forked_chain live import. Reports mean root time over the last 100 blocks.
# `mainCpu` is the cpu time of the calling thread alone (`cpuTime` is
# thread-scoped on Linux), i.e. how busy the main thread is kept while the
# workers hash.
proc scenarioSteady(parallel: bool): (float, float, Hash32) =
  let (db, base) = newDb(100_000)
  db.parallelStateRootComputation = parallel
  var
    txFrame = base
    times, cpuTimes: seq[float]
    root: Hash32
  for blk in 1 .. 130:
    txFrame = db.txFrameBegin(txFrame)
    txFrame.addAccounts(2000)
    let
      c0 = cpuTime()
      t0 = getMonoTime()
    let res = txFrame.computeStateRoot(skipLayers = false)
    times.add ms(getMonoTime() - t0)
    cpuTimes.add (cpuTime() - c0) * 1e3
    doAssert res.isOk()
    root = res[].to(Hash32)
    txFrame.checkpoint(uint64(blk + 1), skipSnapshot = false)
  var s, c = 0.0
  for i in 30 ..< times.len:
    s += times[i]
    c += cpuTimes[i]
  (s / float(times.len - 30), c / float(times.len - 30), root)

# Batch catch-up: 130 blocks imported without root computation, then one deep
# root over all of them (keys span all 130 levels).
proc scenarioCatchup(parallel: bool): (float, float, Hash32) =
  let (db, base) = newDb(100_000)
  db.parallelStateRootComputation = parallel
  var txFrame = base
  for blk in 1 .. 130:
    txFrame = db.txFrameBegin(txFrame)
    txFrame.addAccounts(2000)
    txFrame.checkpoint(uint64(blk + 1), skipSnapshot = true)
  let
    c0 = cpuTime()
    t0 = getMonoTime()
  let res = txFrame.computeStateRoot(skipLayers = false)
  let elapsed = ms(getMonoTime() - t0)
  let mainCpu = (cpuTime() - c0) * 1e3
  doAssert res.isOk()
  (elapsed, mainCpu, res[].to(Hash32))

# Flat bulk import: one large frame on top of the base.
proc scenarioFlat(parallel: bool): (float, float, Hash32) =
  let (db, base) = newDb(100_000)
  db.parallelStateRootComputation = parallel
  var txFrame = db.txFrameBegin(base)
  txFrame.addAccounts(500_000)
  let
    c0 = cpuTime()
    t0 = getMonoTime()
  let res = txFrame.computeStateRoot(skipLayers = false)
  let elapsed = ms(getMonoTime() - t0)
  let mainCpu = (cpuTime() - c0) * 1e3
  doAssert res.isOk()
  (elapsed, mainCpu, res[].to(Hash32))

proc median(xs: var seq[float]): float =
  xs.sort()
  xs[xs.len div 2]

proc run(
    name: string, scenario: proc(parallel: bool): (float, float, Hash32), repeats: int
) =
  var
    serialTimes, parTimes, parCpuTimes: seq[float]
    serialRoot, parRoot: Hash32
  for _ in 0 ..< repeats:
    let (t, _, r) = scenario(false)
    serialTimes.add t
    serialRoot = r
  for _ in 0 ..< repeats:
    let (t, c, r) = scenario(true)
    parTimes.add t
    parCpuTimes.add c
    parRoot = r
  doAssert serialRoot == parRoot, "serial and parallel roots differ!"
  echo &"{name}: serial {median(serialTimes):8.2f} ms | parallel {median(parTimes):8.2f} ms" &
    &" (mainCpu {median(parCpuTimes):8.2f} ms)"

echo &"threads: {numThreads}"
run("steady-state (mean/root, 100 blocks)", scenarioSteady, 1)
run("catch-up (130 blocks, one root)     ", scenarioCatchup, 3)
run("flat 500k accounts (one root)       ", scenarioFlat, 3)
