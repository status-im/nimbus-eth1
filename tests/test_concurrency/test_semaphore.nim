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
  std/os,
  unittest2, 
  ../../execution_chain/concurrency/semaphore

suite "Semaphore Tests":

  test "init sets count correctly":
    var s: Semaphore
    s.init(5)
    # We can wait (decrement) 5 times without blocking
    for _ in 0 ..< 5:
      check s.tryWait() == true
    check s.tryWait() == false
    s.dispose()

  test "init defaults count to 0":
    var s: Semaphore
    s.init()
    check s.tryWait() == false
    s.dispose()

  test "signal increments count":
    var s: Semaphore
    s.init(0)
    check s.tryWait() == false
    s.signal()
    check s.tryWait() == true
    check s.tryWait() == false
    s.dispose()

  test "multiple signals accumulate":
    var s: Semaphore
    s.init(0)
    for _ in 0 ..< 10:
      s.signal()
    for _ in 0 ..< 10:
      check s.tryWait() == true
    check s.tryWait() == false
    s.dispose()

  test "wait does not block when count > 0":
    var s: Semaphore
    s.init(1)
    # Should return immediately without blocking
    s.wait()
    check s.tryWait() == false
    s.dispose()

  test "tryWait returns false when count is 0":
    var s: Semaphore
    s.init(0)
    check s.tryWait() == false
    s.dispose()

  test "tryWait returns true and decrements when count > 0":
    var s: Semaphore
    s.init(2)
    check s.tryWait() == true
    check s.tryWait() == true
    check s.tryWait() == false
    s.dispose()

  test "dispose resets count":
    var s: Semaphore
    s.init(5)
    s.dispose()
    # Reinitialize to verify it's cleanly reset
    s.init(0)
    check s.tryWait() == false
    s.dispose()

  test "signal then wait round-trip":
    var s: Semaphore
    s.init(0)
    s.signal()
    s.wait()
    # Count should now be 0 again
    check s.tryWait() == false
    s.dispose()

  test "multiple threads signal, main thread waits":
    var s: Semaphore
    s.init(0)
    const numThreads = 5
    var workers: array[numThreads, Thread[ptr Semaphore]]

    proc signaler(sp: ptr Semaphore) {.thread, nimcall.} =
      sleep(10)
      sp[].signal()

    for i in 0 ..< numThreads:
      createThread(workers[i], signaler, addr s)

    for _ in 0 ..< numThreads:
      s.wait()

    for i in 0 ..< numThreads:
      joinThread(workers[i])

    check s.tryWait() == false
    s.dispose()

  test "semaphore used as binary lock (mutex-like)":
    var s: Semaphore
    s.init(1)  # Binary semaphore
    var counter = 0
    const iterations = 1000
    const numThreads = 4

    var workers: array[numThreads, Thread[tuple[s: ptr Semaphore, c: ptr int]]]

    proc incrementer(args: tuple[s: ptr Semaphore, c: ptr int]) {.thread.} =
      for _ in 0 ..< iterations:
        args.s[].wait()
        args.c[] += 1
        args.s[].signal()

    for i in 0 ..< numThreads:
      createThread(workers[i], incrementer, (addr s, addr counter))

    for i in 0 ..< numThreads:
      joinThread(workers[i])

    check counter == numThreads * iterations
    s.dispose()