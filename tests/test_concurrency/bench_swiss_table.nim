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
  std/[random, strformat, strutils, tables, times],
  unittest2,
  ../../execution_chain/concurrency/shared_types,
  ../../execution_chain/concurrency/swiss_table

const
  nameWidth = 14
  ops = 2_000_000
  repeats = 3
  sizes = [10_000, 1_000_000]

type BenchStats = object
  elapsed: float
  operations: int
  checksum: uint64

template putKey(t: var Table[int, int], k, v: int) =
  t[k] = v

template putKey(t: var SharedTable[int, int], k, v: int) =
  t.put(k, v)

template putKey(t: var SwissTable[int, int], k, v: int) =
  t.put(k, v)

template delKey(t: var Table[int, int], k: int) =
  t.del(k)

template delKey(t: var SharedTable[int, int], k: int) =
  discard t.del(k)

template delKey(t: var SwissTable[int, int], k: int) =
  discard t.del(k)

template containsKey(t: var Table[int, int], k: int): bool =
  k in t

template containsKey(t: var SharedTable[int, int], k: int): bool =
  t.contains(k)

template containsKey(t: var SwissTable[int, int], k: int): bool =
  t.contains(k)

proc runPut[T](t: var T, keys: openArray[int]): BenchStats =
  mixin putKey
  let started = epochTime()
  for i, k in keys:
    t.putKey(k, i)
  BenchStats(elapsed: epochTime() - started, operations: keys.len)

proc runGet[T](t: var T, keys: openArray[int]): BenchStats =
  mixin withValue
  var checksum: uint64
  let started = epochTime()
  for k in keys:
    t.withValue(k, v):
      checksum += uint64(v[])
  BenchStats(
    elapsed: epochTime() - started, operations: keys.len, checksum: checksum
  )

proc runContains[T](t: var T, keys: openArray[int]): BenchStats =
  mixin containsKey
  var checksum: uint64
  let started = epochTime()
  for k in keys:
    if t.containsKey(k):
      checksum += 1
  BenchStats(
    elapsed: epochTime() - started, operations: keys.len, checksum: checksum
  )

proc runDelPut[T](t: var T, keys: openArray[int]): BenchStats =
  mixin putKey, delKey
  let started = epochTime()
  for i, k in keys:
    t.delKey(k)
    t.putKey(k, i)
  BenchStats(elapsed: epochTime() - started, operations: keys.len)

proc fillStd(size: int): BenchStats =
  var t = initTable[int, int]()
  let started = epochTime()
  for i in 0 ..< size:
    t[i] = i + 1
  result = BenchStats(elapsed: epochTime() - started, operations: size)
  result.checksum = uint64(t.len)

proc fillShared(size: int): BenchStats =
  var t = SharedTable[int, int].init()
  let started = epochTime()
  for i in 0 ..< size:
    t.put(i, i + 1)
  result = BenchStats(elapsed: epochTime() - started, operations: size)
  result.checksum = uint64(t.len)
  t.dispose()

proc fillSwiss(size: int): BenchStats =
  var t = SwissTable[int, int].init()
  let started = epochTime()
  for i in 0 ..< size:
    t.put(i, i + 1)
  result = BenchStats(elapsed: epochTime() - started, operations: size)
  result.checksum = uint64(t.len)
  t.dispose()

proc refill[T](t: var T, size: int) =
  mixin putKey
  t.clear()
  for i in 0 ..< size:
    t.putKey(i, i + 1)

template best(body: untyped): BenchStats =
  block:
    var res: BenchStats
    for r in 0 ..< repeats:
      let cur = body
      doAssert r == 0 or cur.checksum == res.checksum
      if r == 0 or cur.elapsed < res.elapsed:
        res = cur
    res

func nsPerOp(s: BenchStats): float =
  (s.elapsed * 1_000_000_000.0) / s.operations.float

proc header(): string =
  "  " & alignLeft("workload", 24) & alignLeft("table", nameWidth) &
    align("ns/op", 9) & align("ops/s", 14) & align("vs Table", 10) &
    align("vs Shared", 11)

proc row(
    workload, name: string, s, baseStd, baseShared: BenchStats
): string =
  "  " & alignLeft(workload, 24) & alignLeft(name, nameWidth) &
    align(fmt"{s.nsPerOp:.1f}", 9) &
    align(fmt"{s.operations.float / s.elapsed:.0f}", 14) &
    align(fmt"{baseStd.nsPerOp / s.nsPerOp:.2f}x", 10) &
    align(fmt"{baseShared.nsPerOp / s.nsPerOp:.2f}x", 11)

proc report(workload: string, std, shared, swiss: BenchStats) =
  doAssert std.checksum == shared.checksum, workload
  doAssert std.checksum == swiss.checksum, workload
  debugEcho row(workload, "Table", std, std, shared)
  debugEcho row("", "SharedTable", shared, std, shared)
  debugEcho row("", "SwissTable", swiss, std, shared)

suite "SwissTable vs std/tables.Table vs SharedTable":
  test "single threaded throughput":
    var swissWins, total: int

    for size in sizes:
      var rng = initRand(0x1234)
      var
        seqKeys = newSeq[int](ops)
        randKeys = newSeq[int](ops)
        missKeys = newSeq[int](ops)
      for i in 0 ..< ops:
        seqKeys[i] = i mod size
        randKeys[i] = rng.rand(size - 1)
        missKeys[i] = size + rng.rand(size - 1)

      var std = initTable[int, int](size)
      var shared = SharedTable[int, int].init(size)
      var swiss = SwissTable[int, int].init(size)
      defer:
        shared.dispose()
        swiss.dispose()

      std.refill(size)
      shared.refill(size)
      swiss.refill(size)

      let
        stdGetSeq = best(runGet(std, seqKeys))
        sharedGetSeq = best(runGet(shared, seqKeys))
        swissGetSeq = best(runGet(swiss, seqKeys))

        stdGetRand = best(runGet(std, randKeys))
        sharedGetRand = best(runGet(shared, randKeys))
        swissGetRand = best(runGet(swiss, randKeys))

        stdMiss = best(runGet(std, missKeys))
        sharedMiss = best(runGet(shared, missKeys))
        swissMiss = best(runGet(swiss, missKeys))

        stdContains = best(runContains(std, randKeys))
        sharedContains = best(runContains(shared, randKeys))
        swissContains = best(runContains(swiss, randKeys))

        stdUpdate = best(runPut(std, randKeys))
        sharedUpdate = best(runPut(shared, randKeys))
        swissUpdate = best(runPut(swiss, randKeys))

        stdChurn = best(runDelPut(std, randKeys))
        sharedChurn = best(runDelPut(shared, randKeys))
        swissChurn = best(runDelPut(swiss, randKeys))

        stdFill = best(fillStd(size))
        sharedFill = best(fillShared(size))
        swissFill = best(fillSwiss(size))

      debugEcho ""
      debugEcho "  entries=", size, ", ops=", ops, ", best of ", repeats
      debugEcho header()
      report("get hit (sequential)", stdGetSeq, sharedGetSeq, swissGetSeq)
      report("get hit (random)", stdGetRand, sharedGetRand, swissGetRand)
      report("get miss (random)", stdMiss, sharedMiss, swissMiss)
      report("contains (random)", stdContains, sharedContains, swissContains)
      report("put update (random)", stdUpdate, sharedUpdate, swissUpdate)
      report("del+put (random)", stdChurn, sharedChurn, swissChurn)
      report("fill from empty", stdFill, sharedFill, swissFill)

      for (s, o1, o2) in [
        (swissGetSeq, stdGetSeq, sharedGetSeq),
        (swissGetRand, stdGetRand, sharedGetRand),
        (swissMiss, stdMiss, sharedMiss),
        (swissContains, stdContains, sharedContains),
        (swissUpdate, stdUpdate, sharedUpdate),
        (swissChurn, stdChurn, sharedChurn),
        (swissFill, stdFill, sharedFill),
      ]:
        total += 1
        if s.elapsed < o1.elapsed and s.elapsed < o2.elapsed:
          swissWins += 1

      check:
        swissGetRand.elapsed < stdGetRand.elapsed
        swissGetRand.elapsed < sharedGetRand.elapsed
        swissMiss.elapsed < stdMiss.elapsed
        swissMiss.elapsed < sharedMiss.elapsed
        swissContains.elapsed < stdContains.elapsed
        swissContains.elapsed < sharedContains.elapsed

    debugEcho ""
    debugEcho "  SwissTable fastest in ", swissWins, "/", total, " workloads"
