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

import std/[atomics, monotimes, os, strformat, strutils, times]
import ../../execution_chain/concurrency/semaphore

const
  benchIters = 100_000_000

# ---------- helpers ----------------------------------------------------------

template timeIt(label: string, totalOps: int, body: untyped) =
  let t0 = getMonoTime()
  body
  let dt = getMonoTime() - t0
  let ns = dt.inNanoseconds.float
  let opsPerSec = totalOps.float / (ns / 1e9)
  let nsPerOp = ns / totalOps.float
  echo label & " " & $totalOps & " ops " & $nsPerOp & " ns/op " & $opsPerSec & " Mops/s"

# A simple barrier so worker threads start at roughly the same time.
type StartGate = object
  ready: Atomic[int]
  go: Atomic[bool]

proc waitForGo(g: var StartGate) =
  discard g.ready.fetchAdd(1, moRelease)
  while not g.go.load(moAcquire):
    cpuRelax()

proc release(g: var StartGate; expected: int) =
  while g.ready.load(moAcquire) < expected:
    cpuRelax()
  g.go.store(true, moRelease)

# ---------- 1. tryWait fast path ---------------------------------------------

proc benchTryWaitFast() =
  var s: Semaphore
  s.init(benchIters)   # plenty of permits, so every tryWait succeeds

  timeIt("tryWait (fast path, always succeeds)", benchIters):
    var taken = 0
    for _ in 0 ..< benchIters:
      if s.tryWait(): 
        inc taken
    doAssert taken == benchIters

  s.dispose()

proc benchTryWaitEmpty() =
  var s: Semaphore
  s.init(0)            # always empty, every tryWait fails

  timeIt("tryWait (empty, always fails)", benchIters):
    var taken = 0
    for _ in 0 ..< benchIters:
      if s.tryWait(): inc taken
    doAssert taken == 0

  s.dispose()

# ---------- 2. wait/signal ping-pong (single thread) -------------------------

proc benchSignalThenWait() =
  var s: Semaphore
  s.init(0)

  # signal()/wait() pairs: never blocks because count goes 0->1->0 each iter.
  timeIt("signal+wait pairs (single thread, no blocking)", benchIters * 2):
    for _ in 0 ..< benchIters:
      s.signal()
      s.wait()

  s.dispose()

# ---------- 3. producer/consumer (1P / 1C) -----------------------------------

type PCArgs = object
  s: ptr Semaphore
  iters: int
  gate: ptr StartGate

proc producer(a: PCArgs) {.thread.} =
  waitForGo(a.gate[])
  for _ in 0 ..< a.iters:
    a.s[].signal()

proc consumer(a: PCArgs) {.thread.} =
  waitForGo(a.gate[])
  for _ in 0 ..< a.iters:
    a.s[].wait()

proc benchProducerConsumer(producers, consumers: int; perThread: int) =
  var s: Semaphore
  s.init(0)
  var gate: StartGate

  var
    pThreads = newSeq[Thread[PCArgs]](producers)
    cThreads = newSeq[Thread[PCArgs]](consumers)

  # Balance total signals == total waits.
  let pIters = perThread * consumers
  let cIters = perThread * producers
  let totalOps = pIters * producers + cIters * consumers

  for i in 0 ..< producers:
    createThread(pThreads[i], producer,
                 PCArgs(s: addr s, iters: pIters, gate: addr gate))
  for i in 0 ..< consumers:
    createThread(cThreads[i], consumer,
                 PCArgs(s: addr s, iters: cIters, gate: addr gate))

  let label = &"producer/consumer ({producers}P/{consumers}C)"
  timeIt(label, totalOps):
    release(gate, producers + consumers)
    joinThreads(pThreads)
    joinThreads(cThreads)

  s.dispose()

# ---------- 4. heavy contention (count=1, mutex semantics) -------------------

type MutexArgs = object
  s: ptr Semaphore
  shared: ptr int
  iters: int
  gate: ptr StartGate

proc mutexWorker(a: MutexArgs) {.thread.} =
  waitForGo(a.gate[])
  for _ in 0 ..< a.iters:
    a.s[].wait()
    inc a.shared[]      # protected critical section
    a.s[].signal()

proc benchAsMutex(numThreads: int; perThread: int) =
  var s: Semaphore
  s.init(1)
  var gate: StartGate
  var shared = 0

  var threads = newSeq[Thread[MutexArgs]](numThreads)
  for i in 0 ..< numThreads:
    createThread(threads[i], mutexWorker,
                 MutexArgs(s: addr s, shared: addr shared,
                           iters: perThread, gate: addr gate))

  let totalOps = numThreads * perThread * 2  # one wait + one signal per iter
  let label = &"binary semaphore (mutex), {numThreads} threads"
  timeIt(label, totalOps):
    release(gate, numThreads)
    joinThreads(threads)

  doAssert shared == numThreads * perThread,
           &"lost updates: got {shared}, expected {numThreads * perThread}"
  s.dispose()

# ---------- 5. bulk signal then drain ----------------------------------------

type DrainArgs = object
  s: ptr Semaphore
  perThread: int
  gate: ptr StartGate

proc drainer(a: DrainArgs) {.thread.} =
  waitForGo(a.gate[])
  for _ in 0 ..< a.perThread:
    a.s[].wait()

proc benchBulkSignalDrain(numConsumers, perConsumer: int) =
  var s: Semaphore
  s.init(0)
  var gate: StartGate

  var threads = newSeq[Thread[DrainArgs]](numConsumers)
  for i in 0 ..< numConsumers:
    createThread(threads[i], drainer,
                 DrainArgs(s: addr s, perThread: perConsumer, gate: addr gate))

  let total = numConsumers * perConsumer
  let label = &"bulk signal + drain ({numConsumers} consumers)"
  timeIt(label, total * 2):
    release(gate, numConsumers)
    # Producer is the main thread; emit all signals up front.
    for _ in 0 ..< total:
      s.signal()
    joinThreads(threads)

  s.dispose()

# ---------- main -------------------------------------------------------------

proc main() =
  let cpus = 16
  echo &"Semaphore benchmark — iters={benchIters}, cpus={cpus}"
  echo "-".repeat(90)

  # 1. Fast paths (single-thread, no contention)
  benchTryWaitFast()
  benchTryWaitEmpty()
  benchSignalThenWait()
  echo ""

  # 3. Producer/consumer scenarios
  benchProducerConsumer(1, 1, 200_000)
  benchProducerConsumer(2, 2, 100_000)
  benchProducerConsumer(max(1, cpus div 2), max(1, cpus div 2), 50_000)
  echo ""

  # 4. Mutex-style contention (binary semaphore)
  benchAsMutex(2, 100_000)
  benchAsMutex(4, 50_000)
  benchAsMutex(cpus, 25_000)
  echo ""

  # 5. Wakeup throughput
  benchBulkSignalDrain(1, 200_000)
  benchBulkSignalDrain(4, 50_000)
  benchBulkSignalDrain(cpus, 25_000)

when isMainModule:
  main()