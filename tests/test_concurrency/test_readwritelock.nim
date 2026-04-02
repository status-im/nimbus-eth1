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
  std/[atomics, os],
  unittest2,
  ../../execution_chain/concurrency/readwritelock

suite "ReadWriteLock Tests":

  test "init, dispose":
    block:
      var rwLock = ReadWriteLock.init()
      rwLock.dispose()

    block:
      var rwLock: ReadWriteLock
      rwLock.init()
      rwLock.dispose()

  test "Single-thread read lock / unlock":
    var rwl = ReadWriteLock.init()
    rwl.lockRead()
    rwl.unlockRead()
    rwl.dispose()

  test "Single-thread write lock / unlock":
    var rwl = ReadWriteLock.init()
    rwl.lockWrite()
    rwl.unlockWrite()
    rwl.dispose()

  test "Multiple concurrent readers do not block each other":
    const NUM_READERS = 8

    type ConcurrentReadersCtx = object
      rwl: ReadWriteLock
      sharedVal: int
      results: array[NUM_READERS, int]

    var ctx = ConcurrentReadersCtx(sharedVal: 42)
    ctx.rwl.init()

    proc readerThread(args: (ptr ConcurrentReadersCtx, int)) {.thread.} =
      let (ctxPtr, idx) = args
      ctxPtr.rwl.lockRead()
      sleep(10)
      ctxPtr.results[idx] = ctxPtr.sharedVal
      ctxPtr.rwl.unlockRead()

    var threads: array[NUM_READERS, Thread[(ptr ConcurrentReadersCtx, int)]]
    for i in 0 ..< NUM_READERS:
      createThread(threads[i], readerThread, (addr ctx, i))
    for i in 0 ..< NUM_READERS:
      joinThread(threads[i])

    for i in 0 ..< NUM_READERS:
      check ctx.results[i] == 42

    ctx.rwl.dispose()

  test "Writer excludes readers – protected counter":
    const
      NUM_WRITERS = 4
      INCREMENTS_PER_WRITER = 10_000

    type WriterCtx = object
      rwl: ReadWriteLock
      counter: int

    var ctx = WriterCtx(counter: 0)
    ctx.rwl.init()

    proc writerThread(ctxPtr: ptr WriterCtx) {.thread.} =
      for _ in 0 ..< INCREMENTS_PER_WRITER:
        ctxPtr.rwl.lockWrite()
        inc ctxPtr.counter
        ctxPtr.rwl.unlockWrite()

    var threads: array[NUM_WRITERS, Thread[ptr WriterCtx]]
    for i in 0 ..< NUM_WRITERS:
      createThread(threads[i], writerThread, addr ctx)
    for i in 0 ..< NUM_WRITERS:
      joinThread(threads[i])

    check ctx.counter == NUM_WRITERS * INCREMENTS_PER_WRITER

    ctx.rwl.dispose()

  test "Mixed readers and writers – no torn reads":
    const
      NUM_READERS = 4
      NUM_WRITERS = 2
      ITERATIONS = 20_000

    type MixedCtx = object
      rwl: ReadWriteLock
      dataA: int
      dataB: int
      tornRead: Atomic[bool]
      done: Atomic[bool]

    var ctx = MixedCtx(dataA: 0, dataB: 0)
    ctx.rwl.init()
    ctx.tornRead.store(false)
    ctx.done.store(false)

    proc readerProc(ctxPtr: ptr MixedCtx) {.thread.} =
      while not ctxPtr.done.load():
        ctxPtr.rwl.lockRead()
        if ctxPtr.dataA != ctxPtr.dataB:
          ctxPtr.tornRead.store(true)
        ctxPtr.rwl.unlockRead()

    proc writerProc(args: (ptr MixedCtx, int)) {.thread.} =
      let (ctxPtr, id) = args
      for i in 0 ..< ITERATIONS:
        ctxPtr.rwl.lockWrite()
        let v = id * ITERATIONS + i
        ctxPtr.dataA = v
        ctxPtr.dataB = v
        ctxPtr.rwl.unlockWrite()

    var rThreads: array[NUM_READERS, Thread[ptr MixedCtx]]
    var wThreads: array[NUM_WRITERS, Thread[(ptr MixedCtx, int)]]

    for i in 0 ..< NUM_READERS:
      createThread(rThreads[i], readerProc, addr ctx)
    for i in 0 ..< NUM_WRITERS:
      createThread(wThreads[i], writerProc, (addr ctx, i))

    for i in 0 ..< NUM_WRITERS:
      joinThread(wThreads[i])

    ctx.done.store(true)

    for i in 0 ..< NUM_READERS:
      joinThread(rThreads[i])

    check not ctx.tornRead.load()

    ctx.rwl.dispose()

  test "Writers are mutually exclusive":
    const
      NUM_WRITERS = 4
      ITERATIONS = 5_000

    type MutexCtx = object
      rwl: ReadWriteLock
      concurrent: Atomic[int32]
      violation: Atomic[bool]

    var ctx: MutexCtx
    ctx.rwl.init()
    ctx.concurrent.store(0)
    ctx.violation.store(false)

    proc writerProc(ctxPtr: ptr MutexCtx) {.thread.} =
      for _ in 0 ..< ITERATIONS:
        ctxPtr.rwl.lockWrite()
        let prev = ctxPtr.concurrent.fetchAdd(1)
        if prev != 0:
          ctxPtr.violation.store(true)
        discard ctxPtr.concurrent.fetchAdd(-1)
        ctxPtr.rwl.unlockWrite()

    var threads: array[NUM_WRITERS, Thread[ptr MutexCtx]]
    for i in 0 ..< NUM_WRITERS:
      createThread(threads[i], writerProc, addr ctx)
    for i in 0 ..< NUM_WRITERS:
      joinThread(threads[i])

    check not ctx.violation.load()

    ctx.rwl.dispose()

  test "withReadLock template":
    var
      rwl = ReadWriteLock.init()
      value = 100
      observed = 0

    rwl.withReadLock:
      observed = value

    check observed == 100
    rwl.dispose()

  test "withWriteLock template":
    var
      rwl = ReadWriteLock.init()
      value = 0

    rwl.withWriteLock:
      value = 999

    check value == 999
    rwl.dispose()

  test "Sequential reads on same thread":
    var rwl = ReadWriteLock.init()

    rwl.lockRead()
    rwl.unlockRead()
    rwl.lockRead()
    rwl.unlockRead()
    rwl.lockRead()
    rwl.unlockRead()

    rwl.dispose()

  test "Read-then-write sequencing on single thread":
    var
      rwl = ReadWriteLock.init()
      value = 0

    rwl.withReadLock:
      check value == 0

    rwl.withWriteLock:
      value = 42

    rwl.withReadLock:
      check value == 42

    rwl.dispose()