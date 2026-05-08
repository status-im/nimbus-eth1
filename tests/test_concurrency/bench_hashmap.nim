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
  std/[strformat, strutils, tables, times],
  unittest2,
  ../../execution_chain/concurrency/hashmap,
  ../../execution_chain/concurrency/lru

const
  benchNameWidth = 32
  mapCapacity = 100_000
  mapSlots = 200_000 # generous to avoid the put-returns-false path under load
  singleThreadOps = 4_000_000
  opsPerThread = 2_000_000

type
  BenchmarkStats = object
    elapsed: float
    operations: int
    checksum: uint64

  ThreadCtx = object
    map: ptr LockFreeHashMap[int, int]
    threadId: int
    opsCount: int
    checksum: uint64

proc benchmarkHeader(): string =
  "  " & alignLeft("benchmark", benchNameWidth) & " " &
    align("elapsed(s)", 10) & " " & align("ops/s", 14) & " " &
    align("ns/op", 10)

proc benchmarkLine(name: string, stats: BenchmarkStats): string =
  let
    opsPerSec = stats.operations.float / stats.elapsed
    nsPerOp = (stats.elapsed * 1_000_000_000.0) / stats.operations.float
  "  " & alignLeft(name, benchNameWidth) & " " &
    align(fmt"{stats.elapsed:.4f}", 10) & " " &
    align(fmt"{opsPerSec:.0f}", 14) & " " &
    align(fmt"{nsPerOp:.1f}", 10)

# Thread procs must be defined at module level with {.thread.}

proc putThreadProc(ctx: ptr ThreadCtx) {.thread.} =
  # Each thread writes to a disjoint range so capacity is shared but keys
  # don't collide (more representative of typical multi-threaded workloads).
  let base = ctx.threadId * ctx.opsCount
  for i in 0 ..< ctx.opsCount:
    discard ctx.map[].put((base + i) mod mapCapacity, base + i)

proc getThreadProc(ctx: ptr ThreadCtx) {.thread.} =
  var checksum: uint64
  for i in 0 ..< ctx.opsCount:
    let v = ctx.map[].get(i mod mapCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  ctx.checksum = checksum

proc mixedThreadProc(ctx: ptr ThreadCtx) {.thread.} =
  # 25% writes, 75% reads.
  var checksum: uint64
  for i in 0 ..< ctx.opsCount:
    let key = i mod mapCapacity
    if (i and 3) == 0:
      discard ctx.map[].put(key, i)
    else:
      let v = ctx.map[].get(key)
      if v.isOk():
        checksum += uint64(v.unsafeGet()) + 1
  ctx.checksum = checksum

proc runSingleThreadedPut(
    map: ptr LockFreeHashMap[int, int], count: int
): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    discard map[].put(i mod mapCapacity, i)
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runSingleThreadedGet(
    map: ptr LockFreeHashMap[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = map[].get(i mod mapCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runConcurrentLruPut(
    cache: ptr ConcurrentLruCache[int, int], count: int
): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    cache[].put(i mod mapCapacity, i)
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runConcurrentLruGet(
    cache: ptr ConcurrentLruCache[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = cache[].get(i mod mapCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runStdTablePut(
    tbl: ptr Table[int, int], count: int
): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    tbl[][i mod mapCapacity] = i
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runStdTableGet(
    tbl: ptr Table[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = tbl[].getOrDefault(i mod mapCapacity, -1)
    if v != -1:
      checksum += uint64(v) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runBench(
    n: static int,
    threadProc: proc(ctx: ptr ThreadCtx) {.thread.},
    map: ptr LockFreeHashMap[int, int],
): BenchmarkStats =
  var
    threads: array[n, Thread[ptr ThreadCtx]]
    ctxs: array[n, ThreadCtx]
  for i in 0 ..< n:
    ctxs[i] = ThreadCtx(map: map, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< n:
    createThread(threads[i], threadProc, addr ctxs[i])
  var checksum: uint64
  for i in 0 ..< n:
    joinThread(threads[i])
    checksum += ctxs[i].checksum
  BenchmarkStats(
    elapsed: epochTime() - started, operations: n * opsPerThread, checksum: checksum
  )

proc refillMap(map: ptr LockFreeHashMap[int, int]) =
  for i in 0 ..< mapCapacity:
    discard map[].put(i, i + 1) # value = key+1 so key 0 also has a non-zero value

proc refillLru(cache: ptr ConcurrentLruCache[int, int]) =
  for i in 0 ..< mapCapacity:
    cache[].put(i, i + 1)

proc refillTable(tbl: ptr Table[int, int]) =
  for i in 0 ..< mapCapacity:
    tbl[][i] = i + 1

suite "ConcurrentLruCache vs Table vs LockFreeHashMap single-threaded comparison":
  test "Single-threaded throughput comparison":
    var concLru: ConcurrentLruCache[int, int]
    concLru.init(mapCapacity)
    defer:
      concLru.dispose()

    var lfMap = LockFreeHashMap[int, int].init(mapSlots)
    defer:
      lfMap.dispose()

    var stdTbl = initTable[int, int](mapSlots)

    let lruPtr = addr concLru
    let mapPtr = addr lfMap
    let tblPtr = addr stdTbl

    refillLru(lruPtr)
    refillMap(mapPtr)
    refillTable(tblPtr)

    let
      lruPut = runConcurrentLruPut(lruPtr, singleThreadOps)
      lruGet = runConcurrentLruGet(lruPtr, singleThreadOps)
      mapPut = runSingleThreadedPut(mapPtr, singleThreadOps)
      mapGet = runSingleThreadedGet(mapPtr, singleThreadOps)
      tblPut = runStdTablePut(tblPtr, singleThreadOps)
      tblGet = runStdTableGet(tblPtr, singleThreadOps)

    debugEcho ""
    debugEcho "  capacity=", mapCapacity, ", ops=", singleThreadOps
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("ConcurrentLruCache put", lruPut)
    debugEcho benchmarkLine("std/Table put", tblPut)
    debugEcho benchmarkLine("LockFreeHashMap put", mapPut)
    debugEcho benchmarkLine("ConcurrentLruCache get", lruGet)
    debugEcho benchmarkLine("std/Table get", tblGet)
    debugEcho benchmarkLine("LockFreeHashMap get", mapGet)

    check:
      lruPut.elapsed > 0
      lruGet.checksum != 0
      mapPut.elapsed > 0
      mapGet.checksum != 0
      tblPut.elapsed > 0
      tblGet.checksum != 0

suite "LockFreeHashMap Benchmark":
  test "Single and multi-threaded throughput":
    var map = LockFreeHashMap[int, int].init(mapSlots)
    defer:
      map.dispose()

    refillMap(addr map)

    let mapPtr = addr map

    let singlePut = runSingleThreadedPut(mapPtr, singleThreadOps)
    let singleGet = runSingleThreadedGet(mapPtr, singleThreadOps)
    let put2 = runBench(2, putThreadProc, mapPtr)
    refillMap(mapPtr)
    let get2 = runBench(2, getThreadProc, mapPtr)
    let mixed2 = runBench(2, mixedThreadProc, mapPtr)
    let put4 = runBench(4, putThreadProc, mapPtr)
    refillMap(mapPtr)
    let get4 = runBench(4, getThreadProc, mapPtr)
    let mixed4 = runBench(4, mixedThreadProc, mapPtr)
    let put8 = runBench(8, putThreadProc, mapPtr)
    refillMap(mapPtr)
    let get8 = runBench(8, getThreadProc, mapPtr)
    let mixed8 = runBench(8, mixedThreadProc, mapPtr)
    let put16 = runBench(16, putThreadProc, mapPtr)
    refillMap(mapPtr)
    let get16 = runBench(16, getThreadProc, mapPtr)
    let mixed16 = runBench(16, mixedThreadProc, mapPtr)

    debugEcho ""
    debugEcho "  capacity=", mapCapacity,
      ", single-thread ops=", singleThreadOps,
      ", ops/thread (mt)=", opsPerThread
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("1-thread put", singlePut)
    debugEcho benchmarkLine("1-thread get (hot)", singleGet)
    debugEcho benchmarkLine("2-thread put", put2)
    debugEcho benchmarkLine("2-thread get", get2)
    debugEcho benchmarkLine("2-thread mixed (75% read)", mixed2)
    debugEcho benchmarkLine("4-thread put", put4)
    debugEcho benchmarkLine("4-thread get", get4)
    debugEcho benchmarkLine("4-thread mixed (75% read)", mixed4)
    debugEcho benchmarkLine("8-thread put", put8)
    debugEcho benchmarkLine("8-thread get", get8)
    debugEcho benchmarkLine("8-thread mixed (75% read)", mixed8)
    debugEcho benchmarkLine("16-thread put", put16)
    debugEcho benchmarkLine("16-thread get", get16)
    debugEcho benchmarkLine("16-thread mixed (75% read)", mixed16)

    check:
      singlePut.elapsed > 0
      singleGet.elapsed > 0
      singleGet.checksum != 0
      get2.checksum != 0
      get4.checksum != 0
      get8.checksum != 0
      get16.checksum != 0
