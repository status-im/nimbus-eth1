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
  std/[strformat, strutils, times],
  unittest2,
  ../../execution_chain/concurrency/concurrent_lru

const
  benchNameWidth = 32
  cacheCapacity = 100_000
  singleThreadOps = 4_000_000
  opsPerThread = 2_000_000

type
  BenchmarkStats = object
    elapsed: float
    operations: int
    checksum: uint64

  ThreadCtx = object
    cache: ptr ConcurrentLruCache[int, int]
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
  let base = ctx.threadId * ctx.opsCount
  for i in 0 ..< ctx.opsCount:
    ctx.cache[].put(base + i, base + i)

proc getThreadProc(ctx: ptr ThreadCtx) {.thread.} =
  var checksum: uint64
  for i in 0 ..< ctx.opsCount:
    let v = ctx.cache[].get(i mod cacheCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  ctx.checksum = checksum

proc mixedThreadProc(ctx: ptr ThreadCtx) {.thread.} =
  # 25% writes, 75% reads - write to keys in cache range to stay hot
  var checksum: uint64
  for i in 0 ..< ctx.opsCount:
    let key = i mod cacheCapacity
    if (i and 3) == 0:
      ctx.cache[].put(key, i)
    else:
      let v = ctx.cache[].get(key)
      if v.isOk():
        checksum += uint64(v.unsafeGet()) + 1
  ctx.checksum = checksum

proc runSingleThreadedPut(
    cache: ptr ConcurrentLruCache[int, int], count: int
): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    cache[].put(i mod cacheCapacity, i)
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runSingleThreadedGet(
    cache: ptr ConcurrentLruCache[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = cache[].get(i mod cacheCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runPutBench2(cache: ptr ConcurrentLruCache[int, int]): BenchmarkStats =
  var
    threads: array[2, Thread[ptr ThreadCtx]]
    ctxs: array[2, ThreadCtx]
  for i in 0 ..< 2:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< 2:
    createThread(threads[i], putThreadProc, addr ctxs[i])
  for i in 0 ..< 2:
    joinThread(threads[i])
  BenchmarkStats(elapsed: epochTime() - started, operations: 2 * opsPerThread)

proc runGetBench2(cache: ptr ConcurrentLruCache[int, int]): BenchmarkStats =
  var
    threads: array[2, Thread[ptr ThreadCtx]]
    ctxs: array[2, ThreadCtx]
  for i in 0 ..< 2:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< 2:
    createThread(threads[i], getThreadProc, addr ctxs[i])
  var checksum: uint64
  for i in 0 ..< 2:
    joinThread(threads[i])
    checksum += ctxs[i].checksum
  BenchmarkStats(
    elapsed: epochTime() - started, operations: 2 * opsPerThread, checksum: checksum
  )

proc runMixedBench2(cache: ptr ConcurrentLruCache[int, int]): BenchmarkStats =
  var
    threads: array[2, Thread[ptr ThreadCtx]]
    ctxs: array[2, ThreadCtx]
  for i in 0 ..< 2:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< 2:
    createThread(threads[i], mixedThreadProc, addr ctxs[i])
  var checksum: uint64
  for i in 0 ..< 2:
    joinThread(threads[i])
    checksum += ctxs[i].checksum
  BenchmarkStats(
    elapsed: epochTime() - started, operations: 2 * opsPerThread, checksum: checksum
  )

proc runPutBench8(cache: ptr ConcurrentLruCache[int, int]): BenchmarkStats =
  var
    threads: array[8, Thread[ptr ThreadCtx]]
    ctxs: array[8, ThreadCtx]
  for i in 0 ..< 8:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< 8:
    createThread(threads[i], putThreadProc, addr ctxs[i])
  for i in 0 ..< 8:
    joinThread(threads[i])
  BenchmarkStats(elapsed: epochTime() - started, operations: 8 * opsPerThread)

proc runGetBench8(cache: ptr ConcurrentLruCache[int, int]): BenchmarkStats =
  var
    threads: array[8, Thread[ptr ThreadCtx]]
    ctxs: array[8, ThreadCtx]
  for i in 0 ..< 8:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< 8:
    createThread(threads[i], getThreadProc, addr ctxs[i])
  var checksum: uint64
  for i in 0 ..< 8:
    joinThread(threads[i])
    checksum += ctxs[i].checksum
  BenchmarkStats(
    elapsed: epochTime() - started, operations: 8 * opsPerThread, checksum: checksum
  )

proc runMixedBench8(cache: ptr ConcurrentLruCache[int, int]): BenchmarkStats =
  var
    threads: array[8, Thread[ptr ThreadCtx]]
    ctxs: array[8, ThreadCtx]
  for i in 0 ..< 8:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
  let started = epochTime()
  for i in 0 ..< 8:
    createThread(threads[i], mixedThreadProc, addr ctxs[i])
  var checksum: uint64
  for i in 0 ..< 8:
    joinThread(threads[i])
    checksum += ctxs[i].checksum
  BenchmarkStats(
    elapsed: epochTime() - started, operations: 8 * opsPerThread, checksum: checksum
  )

proc refillCache(cache: ptr ConcurrentLruCache[int, int]) =
  for i in 0 ..< cacheCapacity:
    cache[].put(i, i + 1) # value = key+1 so key 0 also has a non-zero value

suite "ConcurrentLruCache Benchmark":
  test "Single and multi-threaded throughput":
    var cache: ConcurrentLruCache[int, int]
    cache.init(cacheCapacity)
    defer:
      cache.dispose()

    refillCache(addr cache)

    let cachePtr = addr cache

    let singlePut = runSingleThreadedPut(cachePtr, singleThreadOps)
    let singleGet = runSingleThreadedGet(cachePtr, singleThreadOps)
    let put2 = runPutBench2(cachePtr)
    refillCache(cachePtr)
    let get2 = runGetBench2(cachePtr)
    let mixed2 = runMixedBench2(cachePtr)
    let put8 = runPutBench8(cachePtr)
    refillCache(cachePtr)
    let get8 = runGetBench8(cachePtr)
    let mixed8 = runMixedBench8(cachePtr)

    debugEcho ""
    debugEcho "ConcurrentLruCache benchmark"
    debugEcho "  capacity=", cacheCapacity,
      ", single-thread ops=", singleThreadOps,
      ", ops/thread (mt)=", opsPerThread
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("1-thread put", singlePut)
    debugEcho benchmarkLine("1-thread get (hot)", singleGet)
    debugEcho benchmarkLine("2-thread put", put2)
    debugEcho benchmarkLine("2-thread get", get2)
    debugEcho benchmarkLine("2-thread mixed (75% read)", mixed2)
    debugEcho benchmarkLine("8-thread put", put8)
    debugEcho benchmarkLine("8-thread get", get8)
    debugEcho benchmarkLine("8-thread mixed (75% read)", mixed8)

    check:
      singlePut.elapsed > 0
      singleGet.elapsed > 0
      singleGet.checksum != 0
      get2.checksum != 0
      get8.checksum != 0
