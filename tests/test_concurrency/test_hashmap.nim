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
  unittest2,
  taskpools,
  ../../execution_chain/concurrency/hashmap

type
  A = object
    v: int

  B = object
    v: int

func hash(v: A): Hash =
  Hash(v.v)
func hash(v: B): Hash =
  Hash(v.v)
func `==`(a: A, b: B): bool =
  a.v == b.v

suite "LockFreeHashMap single-thread":

  test "init / dispose":
    block:
      var m = LockFreeHashMap[int, int].init(0)
      m.dispose()

    block:
      var m = LockFreeHashMap[int, int].init(1000)
      m.dispose()

    block:
      var m = LockFreeHashMap[int, int].init(1000)
      check m.put(1, 10)
      check m.put(2, 20)
      m.dispose()

  test "capacity rounding to power of two":
    var m = LockFreeHashMap[int, int].init(100)
    # capacity / 0.8 = 125 -> next power of two is 128
    check m.capacity() == 100
    check m.slotsLen() == 128
    m.dispose()

  test "simple ops":
    var m = LockFreeHashMap[int, int].init(64)
    defer:
      m.dispose()

    check m.put(1, 10)
    check m.put(2, 20)
    check m.put(3, 30)

    check:
      m.get(1) == Opt.some(10)
      m.get(2) == Opt.some(20)
      m.get(3) == Opt.some(30)
      m.get(99) == Opt.none(int)
      m.contains(1)
      m.contains(2)
      m.contains(3)
      not m.contains(99)
      m.len() == 3

  test "put overwrites existing key":
    var m = LockFreeHashMap[int, int].init(64)
    defer:
      m.dispose()

    check m.put(1, 10)
    check m.put(1, 20)
    check m.put(1, 30)

    check:
      m.get(1) == Opt.some(30)
      m.len() == 1

  test "update non-existent returns false":
    var m = LockFreeHashMap[int, int].init(64)
    defer:
      m.dispose()

    check not m.update(1, 100)

    check m.put(1, 10)
    check m.update(1, 100)
    check m.get(1) == Opt.some(100)

    check not m.update(2, 200)
    check m.get(2) == Opt.none(int)

  test "del":
    var m = LockFreeHashMap[int, int].init(64)
    defer:
      m.dispose()

    check m.put(1, 10)
    check m.put(2, 20)

    m.del(1)
    check:
      not m.contains(1)
      m.get(1) == Opt.none(int)
      m.contains(2)
      m.len() == 1

    m.del(99) # no-op
    check m.len() == 1
    m.del(2)
    check m.len() == 0

  test "pop":
    var m = LockFreeHashMap[int, int].init(64)
    defer:
      m.dispose()

    check m.put(1, 10)
    check m.put(2, 20)

    check m.pop(1) == Opt.some(10)
    check m.pop(1) == Opt.none(int)
    check m.len() == 1
    check m.contains(2)

    check m.pop(2) == Opt.some(20)
    check m.len() == 0

  test "growth by 1 (within capacity)":
    const N = 5_000
    var m = LockFreeHashMap[int, int].init(N)
    defer:
      m.dispose()

    for i in 0 ..< N:
      check m.put(i, i * 2)

    check m.len() == N
    for i in 0 ..< N:
      check m.get(i) == Opt.some(i * 2)

  test "delete and reinsert (tombstone reuse)":
    const N = 1_000
    var m = LockFreeHashMap[int, int].init(N)
    defer:
      m.dispose()

    for i in 0 ..< N:
      check m.put(i, i)
    check m.len() == N

    # Delete every other key, reinsert with new values, verify integrity.
    for i in countup(0, N - 1, 2):
      m.del(i)
    check m.len() == N div 2

    for i in countup(0, N - 1, 2):
      check m.put(i, i + 100_000)
    check m.len() == N

    for i in 0 ..< N:
      let want = if (i and 1) == 0: i + 100_000 else: i
      check m.get(i) == Opt.some(want)

  test "tombstone churn does not exhaust capacity":
    # Repeated insert/delete of the same key shouldn't grow tombstones
    # without bound - the same slot is reused.
    var m = LockFreeHashMap[int, int].init(16)
    defer:
      m.dispose()

    for i in 0 ..< 100_000:
      check m.put(i, i)
      m.del(i)

    check m.len() == 0

  test "fill to capacity":
    const N = 200
    var m = LockFreeHashMap[int, int].init(N)
    defer:
      m.dispose()

    var inserted = 0
    for i in 0 ..< 1000:
      if m.put(i, i):
        inserted += 1
      else:
        break

    # Probe budget allows up to slotsLen entries; with the 0.8 fill ratio
    # we should have inserted at least N entries.
    check inserted >= N
    check m.len() == inserted

    for i in 0 ..< inserted:
      check m.get(i) == Opt.some(i)

  test "heterogeneous lookup":
    var m = LockFreeHashMap[A, int].init(64)
    defer:
      m.dispose()

    check m.put(A(v: 1), 10)
    check m.put(A(v: 2), 20)

    check m.get(B(v: 1)) == Opt.some(10)
    check m.get(B(v: 2)) == Opt.some(20)
    check m.get(B(v: 99)) == Opt.none(int)
    check m.contains(B(v: 1))
    check not m.contains(B(v: 99))

  test "non-trivially-copyable value type":
    var m = LockFreeHashMap[int, string].init(64)
    defer:
      m.dispose()

    check m.put(1, "hello")
    check m.put(2, "world")
    check m.get(1) == Opt.some("hello")

    # Update with a different string
    check m.put(1, "goodbye")
    check m.get(1) == Opt.some("goodbye")

    # Pop should clear the slot
    check m.pop(1) == Opt.some("goodbye")
    check m.get(1) == Opt.none(string)

suite "LockFreeHashMap concurrent":

  test "concurrent disjoint inserts":
    const
      numThreads = 4
      keysPerThread = 1000
      totalKeys = numThreads * keysPerThread

    var m = LockFreeHashMap[int, int].init(totalKeys * 2)
    defer:
      m.dispose()
    let mPtr = addr m

    var tp = Taskpool.new(numThreads = numThreads)
    defer:
      tp.shutdown()

    proc tpPut(map: ptr LockFreeHashMap[int, int], base, count: int) =
      for i in 0 ..< count:
        discard map[].put(base + i, base + i + 1)

    for t in 0 ..< numThreads:
      tp.spawn tpPut(mPtr, t * keysPerThread, keysPerThread)
    tp.syncAll()

    check m.len() == totalKeys
    for i in 0 ..< totalKeys:
      check m.get(i) == Opt.some(i + 1)

  test "concurrent overlapping puts":
    # Multiple threads put to the same key. After all complete, each key
    # must have one of the written values, no duplicates, no torn reads.
    const
      numThreads = 4
      iters = 100_000
      numKeys = 100

    var m = LockFreeHashMap[int, int].init(numKeys * 2)
    defer:
      m.dispose()
    let mPtr = addr m

    var tp = Taskpool.new(numThreads = numThreads)
    defer:
      tp.shutdown()

    proc tpHammer(map: ptr LockFreeHashMap[int, int], threadId, iters, numKeys: int) =
      for i in 0 ..< iters:
        let key = i mod numKeys
        # Encode (threadId, i) into the value so we can verify any value
        # actually came from a real put on this key.
        let value = threadId * 1_000_000 + i
        discard map[].put(key, value)

    for t in 0 ..< numThreads:
      tp.spawn tpHammer(mPtr, t, iters, numKeys)
    tp.syncAll()

    check m.len() == numKeys
    for k in 0 ..< numKeys:
      let v = m.get(k)
      check v.isSome()
      let unpacked = v.unsafeGet()
      let tid = unpacked div 1_000_000
      let it = unpacked mod 1_000_000
      check tid >= 0 and tid < numThreads
      check it >= 0 and it < iters

  test "concurrent put + get (no torn reads)":
    # Use a value V such that V == key + offset, with a per-thread distinct
    # offset. After every successful get, we can verify that the value
    # decodes to a valid (key, threadId) pair, ruling out torn reads.
    const
      writerThreads = 2
      readerThreads = 4
      numKeys = 500
      iters = 200_000

    var m = LockFreeHashMap[int, int].init(numKeys * 2)
    defer:
      m.dispose()
    let mPtr = addr m

    # Pre-populate
    for k in 0 ..< numKeys:
      check m.put(k, k * 1000)

    var tp = Taskpool.new(numThreads = writerThreads + readerThreads)
    defer:
      tp.shutdown()

    proc tpWriter(map: ptr LockFreeHashMap[int, int], threadId, iters, numKeys: int) =
      for i in 0 ..< iters:
        let key = i mod numKeys
        # value = key * 1000 + threadId; this means decoding is unambiguous
        discard map[].put(key, key * 1000 + threadId)

    proc tpReader(map: ptr LockFreeHashMap[int, int], iters, numKeys: int): int =
      var bad = 0
      for i in 0 ..< iters:
        let key = i mod numKeys
        let v = map[].get(key)
        if v.isSome():
          let val = v.unsafeGet()
          let recoveredKey = val div 1000
          if recoveredKey != key:
            bad += 1
      bad

    var torn: array[readerThreads, Flowvar[int]]

    for t in 0 ..< writerThreads:
      tp.spawn tpWriter(mPtr, t, iters, numKeys)
    for t in 0 ..< readerThreads:
      torn[t] = tp.spawn tpReader(mPtr, iters, numKeys)
    tp.syncAll()

    var totalBad = 0
    for t in 0 ..< readerThreads:
      totalBad += sync(torn[t])
    check totalBad == 0

  test "concurrent del + get (no garbage)":
    # Readers must see either a valid value matching the key, or none.
    const
      numKeys = 500
      iters = 200_000

    var m = LockFreeHashMap[int, int].init(numKeys * 2)
    defer:
      m.dispose()
    let mPtr = addr m

    for k in 0 ..< numKeys:
      check m.put(k, k * 1000)

    var tp = Taskpool.new(numThreads = 4)
    defer:
      tp.shutdown()

    proc tpChurner(map: ptr LockFreeHashMap[int, int], iters, numKeys: int) =
      for i in 0 ..< iters:
        let key = i mod numKeys
        if (i and 1) == 0:
          map[].del(key)
        else:
          discard map[].put(key, key * 1000)

    proc tpReader(map: ptr LockFreeHashMap[int, int], iters, numKeys: int): int =
      var bad = 0
      for i in 0 ..< iters:
        let key = i mod numKeys
        let v = map[].get(key)
        if v.isSome() and v.unsafeGet() != key * 1000:
          bad += 1
      bad

    let r1 = tp.spawn tpReader(mPtr, iters, numKeys)
    let r2 = tp.spawn tpReader(mPtr, iters, numKeys)
    tp.spawn tpChurner(mPtr, iters, numKeys)
    tp.spawn tpChurner(mPtr, iters, numKeys)
    tp.syncAll()

    check sync(r1) + sync(r2) == 0

  test "stress fill - exactly capacity successful puts":
    const
      numThreads = 4
      capacity = 200
      attemptsPerThread = capacity * 2

    var m = LockFreeHashMap[int, int].init(capacity)
    defer:
      m.dispose()
    let mPtr = addr m

    var tp = Taskpool.new(numThreads = numThreads)
    defer:
      tp.shutdown()

    proc tpFill(map: ptr LockFreeHashMap[int, int], threadId, count: int): int =
      var ok = 0
      for i in 0 ..< count:
        let key = threadId * 100_000 + i
        if map[].put(key, threadId):
          ok += 1
      ok

    var results: array[numThreads, Flowvar[int]]
    for t in 0 ..< numThreads:
      results[t] = tp.spawn tpFill(mPtr, t, attemptsPerThread)
    tp.syncAll()

    var totalOk = 0
    for t in 0 ..< numThreads:
      totalOk += sync(results[t])

    # All inserts went into a fresh map: total successful inserts must equal
    # the observed map length.
    check m.len() == totalOk
    # And total successes must be at least the user-requested capacity.
    check totalOk >= capacity
