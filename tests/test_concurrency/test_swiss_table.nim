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
  std/[algorithm, importutils, random, sequtils, tables],
  unittest2,
  ../../execution_chain/concurrency/shared_types,
  ../../execution_chain/concurrency/swiss_table {.all.}

privateAccess(SwissTable)

func slotCount[K, V](s: SwissTable[K, V]): int =
  s.capacity

func isPowerOfTwoOrZero(n: int): bool =
  n == 0 or (n and (n - 1)) == 0

type
  Key = object
    v: int

  CollKey = object
    v: int

func hash(k: Key): Hash =
  Hash(k.v)

func hash(k: CollKey): Hash =
  Hash(0)

suite "SwissTable Tests":
  test "empty table":
    var t = SwissTable[int, int].init()
    check:
      t.len == 0
      t.slotCount == 0
      not t.contains(0)
      t.get(0).isNone()
      t[0].isNone()
      not t.del(0)
      t.pop(0).isNone()
    t.dispose()

  test "put, get and contains":
    var t = SwissTable[int, int].init()
    t.put(1, 10)
    t.put(2, 20)
    t[3] = 30

    check:
      t.len == 3
      t.contains(1)
      t.contains(2)
      t.contains(3)
      not t.contains(4)
      t.get(1) == Opt.some(10)
      t[2] == Opt.some(20)
      t.get(3) == Opt.some(30)
    t.dispose()

  test "getOrDefault returns the value when present or a default when absent":
    var t = SwissTable[int, int].init()
    t.put(1, 10)

    check:
      t.getOrDefault(1) == 10
      t.getOrDefault(2) == 0
      t.getOrDefault(1, -1) == 10
      t.getOrDefault(2, -1) == -1
      t.len == 1
    t.dispose()

  test "put updates an existing key without changing len":
    var t = SwissTable[int, int].init()
    t.put(1, 10)
    let start = t.slotCount
    check t.len == 1

    for i in 0 ..< 100:
      t.put(1, i)
    check:
      t.len == 1
      t.get(1) == Opt.some(99)
      t.slotCount == start
    t.dispose()

  test "del removes entries and reports presence":
    var t = SwissTable[int, int].init()
    for i in 0 ..< 10:
      t.put(i, i)

    check:
      t.del(5)
      t.len == 9
      not t.contains(5)
      not t.del(5)

    for i in 0 ..< 10:
      if i == 5:
        check not t.contains(i)
      else:
        check t.get(i) == Opt.some(i)
    t.dispose()

  test "pop removes and returns the value":
    var t = SwissTable[int, int].init()
    for i in 0 ..< 10:
      t.put(i, i * 7)

    check:
      t.pop(3) == Opt.some(21)
      t.len == 9
      t.pop(3).isNone()
      not t.contains(3)
    t.dispose()

  test "grows by powers of two as it fills":
    var t = SwissTable[int, int].init()
    check t.slotCount == 0

    for i in 0 ..< 1000:
      t.put(i, i)
      check isPowerOfTwoOrZero(t.slotCount)

    check:
      t.len == 1000
      isPowerOfTwoOrZero(t.slotCount)
      t.slotCount >= 1000

    for i in 0 ..< 1000:
      check t.get(i) == Opt.some(i)
    t.dispose()

  test "never exceeds the 7/8 load factor":
    var t = SwissTable[int, int].init()
    for i in 0 ..< 5000:
      t.put(i, i)
      check t.len * 8 <= t.slotCount * 7
    t.dispose()

  test "init with initialSize preallocates and avoids early growth":
    var t = SwissTable[int, int].init(100)
    let start = t.slotCount
    check:
      isPowerOfTwoOrZero(start)
      start * 7 >= 100 * 8

    for i in 0 ..< 100:
      t.put(i, i)
    check:
      t.slotCount == start
      t.len == 100
    t.dispose()

  test "heavy churn of inserts and deletes":
    var t = SwissTable[int, int].init()

    for i in 0 ..< 500:
      t.put(i, i * 2)

    for i in countup(0, 499, 2):
      check t.del(i)
    check t.len == 250

    for i in countup(0, 499, 2):
      t.put(i, i * 3)
    check t.len == 500

    for i in 0 ..< 500:
      let expected = if i mod 2 == 0: i * 3 else: i * 2
      check t.get(i) == Opt.some(expected)
    t.dispose()

  test "repeated delete and reinsert reclaims tombstones without unbounded growth":
    var t = SwissTable[int, int].init(1000)
    for i in 0 ..< 1000:
      t.put(i, i)
    let start = t.slotCount

    for round in 0 ..< 100:
      for i in 0 ..< 1000:
        check t.del(i)
        t.put(i, i + round)

    check:
      t.len == 1000
      t.slotCount == start
    for i in 0 ..< 1000:
      check t.get(i) == Opt.some(i + 99)
    t.dispose()

  test "colliding keys share one probe sequence":
    var t = SwissTable[CollKey, int].init()
    for i in 0 ..< 200:
      t.put(CollKey(v: i), i)
    check t.len == 200

    for i in countup(0, 199, 3):
      check t.del(CollKey(v: i))

    for i in 0 ..< 200:
      if i mod 3 == 0:
        check not t.contains(CollKey(v: i))
      else:
        check t.get(CollKey(v: i)) == Opt.some(i)
    t.dispose()

  test "clear empties the table but keeps the allocation":
    var t = SwissTable[int, int].init()
    for i in 0 ..< 50:
      t.put(i, i)
    let alloc = t.slotCount

    t.clear()
    check:
      t.len == 0
      t.slotCount == alloc
      not t.contains(0)

    t.put(1, 1)
    check t.get(1) == Opt.some(1)
    t.dispose()

  test "dispose resets and is idempotent":
    var t = SwissTable[int, int].init(10)
    t.put(1, 1)

    t.dispose()
    check:
      t.len == 0
      t.slotCount == 0
      not t.contains(1)

    t.dispose()
    check t.len == 0

  test "move transfers ownership and clears the source":
    var a = SwissTable[int, int].init()
    a.put(1, 10)
    a.put(2, 20)

    var b = move(a)
    check:
      b.len == 2
      b.get(1) == Opt.some(10)
      a.len == 0
      not a.contains(1)

    b.dispose()
    a.dispose()

  test "works with a custom key type and hash":
    var t = SwissTable[Key, int].init()
    for i in 0 ..< 100:
      t.put(Key(v: i), i * 100)

    check:
      t.get(Key(v: 1)) == Opt.some(100)
      t.get(Key(v: 99)) == Opt.some(9900)
      not t.contains(Key(v: 100))
    t.dispose()

  test "withValue runs the do-block branch only when the key is missing":
    var t = SwissTable[int, int].init()
    t.put(1, 10)

    var present = 0
    var missingRan = false
    t.withValue(1, v):
      v[] = 11
      present = v[]
    do:
      missingRan = true
    check:
      present == 11
      not missingRan
      t.get(1) == Opt.some(11)

    var foundRan = false
    var inserted = false
    t.withValue(2, v):
      foundRan = true
    do:
      inserted = true
      t[2] = 20
    check:
      not foundRan
      inserted
      t.get(2) == Opt.some(20)
    t.dispose()

  test "iterators visit every live entry exactly once":
    var t = SwissTable[int, int].init()
    for i in 0 ..< 300:
      t.put(i, i * 2)
    for i in countup(0, 299, 5):
      check t.del(i)

    var
      keys: seq[int]
      values: seq[int]
      pairKeys: seq[int]
    for k in t.keys():
      keys.add(k)
    for v in t.values():
      values.add(v)
    for k, v in t.pairs():
      pairKeys.add(k)
      check v == k * 2

    let expected = toSeq(0 ..< 300).filterIt(it mod 5 != 0)
    check:
      keys.len == t.len
      values.len == t.len
      pairKeys.len == t.len
      keys.sorted() == expected
      values.sorted() == expected.mapIt(it * 2)

    for v in t.mvalues():
      v += 1
    check t.get(1) == Opt.some(3)

    for k, v in t.mpairs():
      v = k
    for i in 0 ..< 300:
      if i mod 5 != 0:
        check t.get(i) == Opt.some(i)
    t.dispose()

  test "matches std/tables under a randomised sequence of operations":
    var
      rng = initRand(0xC0FFEE)
      model = initTable[int, int]()
      t = SwissTable[int, int].init()

    for step in 0 ..< 200_000:
      let key = rng.rand(2_000)
      case rng.rand(9)
      of 0 .. 4:
        model[key] = step
        t.put(key, step)
      of 5 .. 7:
        check t.del(key) == model.hasKey(key)
        model.del(key)
      else:
        check t.contains(key) == model.hasKey(key)
        if model.hasKey(key):
          check t.get(key) == Opt.some(model[key])
        else:
          check t.get(key).isNone()
      check t.len == model.len

    for k, v in model:
      check t.get(k) == Opt.some(v)
    for k, v in t.pairs():
      check model[k] == v
    t.dispose()

  test "alloc and dispose does not leak shared memory":
    let before = getOccupiedSharedMem()
    for _ in 0 ..< 100:
      var t = SwissTable[int, int].init()
      for i in 0 ..< 1000:
        t.put(i, i)
      for i in countup(0, 999, 2):
        check t.del(i)
      t.dispose()
    check getOccupiedSharedMem() == before

suite "SwissTable with move-only values Tests":
  test "stores and retrieves SharedBytes values via withValue":
    var t = SwissTable[int, SharedBytes].init()
    t.put(1, SharedBytes.init([1'u8, 2, 3]))
    t.put(2, SharedBytes.init([4'u8, 5, 6]))

    check:
      t.len == 2
      t.contains(1)
      t.contains(2)
      not t.contains(3)

    var seen1 = false
    t.withValue(1, v):
      check v[].data() == @[1'u8, 2, 3]
      seen1 = true
    check seen1

    var ranMissing = false
    t.withValue(99, v):
      ranMissing = true
    check not ranMissing

    for v in t.mvalues():
      dispose(v)
    t.dispose()

  test "resize moves move-only values":
    var t = SwissTable[CollKey, SharedBytes].init()
    for i in 0 ..< 100:
      t.put(CollKey(v: i), SharedBytes.init([byte(i), byte(i + 1)]))
    check t.len == 100

    for i in 0 ..< 100:
      var ok = false
      t.withValue(CollKey(v: i), v):
        check v[].data() == @[byte(i), byte(i + 1)]
        ok = true
      check ok

    for v in t.mvalues():
      dispose(v)
    t.dispose()

  test "pop does not leak move-only values":
    let before = getOccupiedSharedMem()
    for _ in 0 ..< 100:
      var t = SwissTable[int, SharedBytes].init()
      t[1] = SharedBytes.init([1'u8, 2, 3, 4, 5, 6, 7, 8])
      t[2] = SharedBytes.init([9'u8, 9])
      var popped = t.pop(1)
      popped.unsafeGet().dispose()
      for v in t.mvalues():
        v.dispose()
      t.dispose()
    check getOccupiedSharedMem() == before

  test "holds nested SwissTable values":
    var outer = SwissTable[CollKey, SwissTable[int, int]].init()

    for i in 0 ..< 10:
      var inner = SwissTable[int, int].init()
      inner.put(i, i * 100)
      inner.put(i + 1000, i)
      outer.put(CollKey(v: i), move(inner))
    check outer.len == 10

    var innerLen = 0
    outer.withValue(CollKey(v: 3), inner):
      check inner[].get(3) == Opt.some(300)
      check inner[].get(1003) == Opt.some(3)
      innerLen = inner[].len
    check innerLen == 2

    outer.withValue(CollKey(v: 4), inner):
      inner[].dispose()
    check outer.del(CollKey(v: 4))
    check outer.len == 9

    for i in 0 ..< 10:
      if i == 4:
        check not outer.contains(CollKey(v: i))
      else:
        var ok = false
        outer.withValue(CollKey(v: i), inner):
          check inner[].get(i) == Opt.some(i * 100)
          ok = true
        check ok

    for inner in outer.mvalues():
      inner.dispose()
    outer.dispose()
