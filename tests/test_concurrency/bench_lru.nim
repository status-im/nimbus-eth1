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
  minilru,
  unittest2,
  ../../execution_chain/concurrency/lru

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

proc peekThreadProc(ctx: ptr ThreadCtx) {.thread.} =
  var checksum: uint64
  for i in 0 ..< ctx.opsCount:
    let v = ctx.cache[].peek(i mod cacheCapacity)
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

proc runSingleThreadedPeek(
    cache: ptr ConcurrentLruCache[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = cache[].peek(i mod cacheCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runLruPut(
    cache: ptr LruCache[int, int], count: int
): BenchmarkStats =
  let started = epochTime()
  for i in 0 ..< count:
    cache[].put(i mod cacheCapacity, i)
  BenchmarkStats(elapsed: epochTime() - started, operations: count)

proc runLruGet(
    cache: ptr LruCache[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = cache[].get(i mod cacheCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runLruPeek(
    cache: ptr LruCache[int, int], count: int
): BenchmarkStats =
  var checksum: uint64
  let started = epochTime()
  for i in 0 ..< count:
    let v = cache[].peek(i mod cacheCapacity)
    if v.isOk():
      checksum += uint64(v.unsafeGet()) + 1
  BenchmarkStats(elapsed: epochTime() - started, operations: count, checksum: checksum)

proc runBench(
    n: static int,
    threadProc: proc(ctx: ptr ThreadCtx) {.thread.},
    cache: ptr ConcurrentLruCache[int, int],
): BenchmarkStats =
  var
    threads: array[n, Thread[ptr ThreadCtx]]
    ctxs: array[n, ThreadCtx]
  for i in 0 ..< n:
    ctxs[i] = ThreadCtx(cache: cache, threadId: i, opsCount: opsPerThread)
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

proc refillCache(cache: ptr ConcurrentLruCache[int, int]) =
  for i in 0 ..< cacheCapacity:
    cache[].put(i, i + 1) # value = key+1 so key 0 also has a non-zero value

proc refillLru(cache: ptr LruCache[int, int]) =
  for i in 0 ..< cacheCapacity:
    cache[].put(i, i + 1)

suite "LruCache vs ConcurrentLruCache single-threaded comparison":
  test "Single-threaded throughput comparison":
    var lru = LruCache[int, int].init(cacheCapacity)
    # defer:
    #   lru.dispose()

    var concLru: ConcurrentLruCache[int, int]
    concLru.init(cacheCapacity)
    defer:
      concLru.dispose()

    let lruPtr = addr lru
    let concPtr = addr concLru

    refillLru(lruPtr)
    refillCache(concPtr)

    let
      lruPut = runLruPut(lruPtr, singleThreadOps)
      lruGet = runLruGet(lruPtr, singleThreadOps)
      lruPeek = runLruPeek(lruPtr, singleThreadOps)
      concPut = runSingleThreadedPut(concPtr, singleThreadOps)
      concGet = runSingleThreadedGet(concPtr, singleThreadOps)
      concPeek = runSingleThreadedPeek(concPtr, singleThreadOps)

    debugEcho ""
    debugEcho "  capacity=", cacheCapacity, ", ops=", singleThreadOps
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("LruCache put", lruPut)
    debugEcho benchmarkLine("ConcurrentLruCache put", concPut)
    debugEcho benchmarkLine("LruCache get", lruGet)
    debugEcho benchmarkLine("ConcurrentLruCache get", concGet)
    debugEcho benchmarkLine("LruCache peek", lruPeek)
    debugEcho benchmarkLine("ConcurrentLruCache peek", concPeek)

    check:
      lruPut.elapsed > 0
      lruGet.checksum != 0
      lruPeek.checksum != 0
      concPut.elapsed > 0
      concGet.checksum != 0
      concPeek.checksum != 0

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
    let singlePeek = runSingleThreadedPeek(cachePtr, singleThreadOps)
    let put2 = runBench(2, putThreadProc, cachePtr)
    refillCache(cachePtr)
    let get2 = runBench(2, getThreadProc, cachePtr)
    let peek2 = runBench(2, peekThreadProc, cachePtr)
    let mixed2 = runBench(2, mixedThreadProc, cachePtr)
    let put4 = runBench(4, putThreadProc, cachePtr)
    refillCache(cachePtr)
    let get4 = runBench(4, getThreadProc, cachePtr)
    let peek4 = runBench(4, peekThreadProc, cachePtr)
    let mixed4 = runBench(4, mixedThreadProc, cachePtr)
    let put8 = runBench(8, putThreadProc, cachePtr)
    refillCache(cachePtr)
    let get8 = runBench(8, getThreadProc, cachePtr)
    let peek8 = runBench(8, peekThreadProc, cachePtr)
    let mixed8 = runBench(8, mixedThreadProc, cachePtr)
    let put16 = runBench(16, putThreadProc, cachePtr)
    refillCache(cachePtr)
    let get16 = runBench(16, getThreadProc, cachePtr)
    let peek16 = runBench(16, peekThreadProc, cachePtr)
    let mixed16 = runBench(16, mixedThreadProc, cachePtr)

    debugEcho ""
    debugEcho "  capacity=", cacheCapacity,
      ", single-thread ops=", singleThreadOps,
      ", ops/thread (mt)=", opsPerThread
    debugEcho benchmarkHeader()
    debugEcho benchmarkLine("1-thread put", singlePut)
    debugEcho benchmarkLine("1-thread get (hot)", singleGet)
    debugEcho benchmarkLine("1-thread peek (hot)", singlePeek)
    debugEcho benchmarkLine("2-thread put", put2)
    debugEcho benchmarkLine("2-thread get", get2)
    debugEcho benchmarkLine("2-thread peek", peek2)
    debugEcho benchmarkLine("2-thread mixed (75% read)", mixed2)
    debugEcho benchmarkLine("4-thread put", put4)
    debugEcho benchmarkLine("4-thread get", get4)
    debugEcho benchmarkLine("4-thread peek", peek4)
    debugEcho benchmarkLine("4-thread mixed (75% read)", mixed4)
    debugEcho benchmarkLine("8-thread put", put8)
    debugEcho benchmarkLine("8-thread get", get8)
    debugEcho benchmarkLine("8-thread peek", peek8)
    debugEcho benchmarkLine("8-thread mixed (75% read)", mixed8)
    debugEcho benchmarkLine("16-thread put", put16)
    debugEcho benchmarkLine("16-thread get", get16)
    debugEcho benchmarkLine("16-thread peek", peek16)
    debugEcho benchmarkLine("16-thread mixed (75% read)", mixed16)

    check:
      singlePut.elapsed > 0
      singleGet.elapsed > 0
      singleGet.checksum != 0
      singlePeek.checksum != 0
      get2.checksum != 0
      peek2.checksum != 0
      get4.checksum != 0
      peek4.checksum != 0
      get8.checksum != 0
      peek8.checksum != 0
      get16.checksum != 0
      peek16.checksum != 0
