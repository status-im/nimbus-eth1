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
  std/importutils, unittest2, ../../execution_chain/concurrency/shared_types {.all.}

privateAccess(SharedTable)

func allocated[K, V](s: SharedTable[K, V]): int =
  s.allocated

func isPowerOfTwoOrZero(n: int): bool =
  n == 0 or (n and (n - 1)) == 0

type
  Key = object
    v: int

func hash(k: Key): Hash =
  Hash(k.v)

suite "SharedTable Tests":
  test "empty table":
    var t = SharedTable[int, int].init()
    check:
      t.len == 0
      not t.contains(0)
      t.get(0).isNone()
      t[0].isNone()
      not t.del(0)
    t.dispose()

  test "put, get and contains":
    var t = SharedTable[int, int].init()
    t.put(1, 10)
    t.put(2, 20)
    t[3] = 30 # `[]=` alias

    check:
      t.len == 3
      t.contains(1)
      t.contains(2)
      t.contains(3)
      not t.contains(4)
      t.get(1) == Opt.some(10)
      t[2] == Opt.some(20) # `[]` alias
      t.get(3) == Opt.some(30)
    t.dispose()

  test "put updates an existing key without changing len":
    var t = SharedTable[int, int].init()
    t.put(1, 10)
    check t.len == 1

    t.put(1, 99)
    check:
      t.len == 1
      t.get(1) == Opt.some(99)
    t.dispose()

  test "del removes entries and reports presence":
    var t = SharedTable[int, int].init()
    for i in 0 ..< 10:
      t.put(i, i)

    check:
      t.del(5)
      t.len == 9
      not t.contains(5)
      not t.del(5) # already gone

    # The remaining entries are still reachable (backward-shift kept them valid)
    for i in 0 ..< 10:
      if i == 5:
        check not t.contains(i)
      else:
        check t.get(i) == Opt.some(i)
    t.dispose()

  test "grows by powers of two as it fills":
    var t = SharedTable[int, int].init()
    check t.allocated == 0

    for i in 0 ..< 1000:
      t.put(i, i)
      check isPowerOfTwoOrZero(t.allocated)

    check:
      t.len == 1000
      isPowerOfTwoOrZero(t.allocated)
      t.allocated >= 1000

    # All entries survive the rehashes triggered by growth
    for i in 0 ..< 1000:
      check t.get(i) == Opt.some(i)
    t.dispose()

  test "init with initialSize preallocates and avoids early growth":
    var t = SharedTable[int, int].init(100)
    let start = t.allocated
    check:
      isPowerOfTwoOrZero(start)
      start >= 100

    for i in 0 ..< 80: # below the fill ratio of the initial allocation
      t.put(i, i)
    check t.allocated == start
    t.dispose()

  test "heavy churn of inserts and deletes":
    var t = SharedTable[int, int].init()

    for i in 0 ..< 500:
      t.put(i, i * 2)

    # Delete the even keys, then re-insert them with new values
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

  test "clear empties the table but keeps the allocation":
    var t = SharedTable[int, int].init()
    for i in 0 ..< 50:
      t.put(i, i)
    let alloc = t.allocated

    t.clear()
    check:
      t.len == 0
      t.allocated == alloc
      not t.contains(0)

    # Still usable after clear
    t.put(1, 1)
    check t.get(1) == Opt.some(1)
    t.dispose()

  test "dispose resets and is idempotent":
    var t = SharedTable[int, int].init(10)
    t.put(1, 1)

    t.dispose()
    check:
      t.len == 0
      t.allocated == 0
      not t.contains(1)

    t.dispose() # second dispose must be a safe no-op
    check t.len == 0

  test "move transfers ownership and clears the source":
    var a = SharedTable[int, int].init()
    a.put(1, 10)
    a.put(2, 20)

    var b = move(a)
    check:
      b.len == 2
      b.get(1) == Opt.some(10)
      a.len == 0 # the moved-from value is reset
      not a.contains(1)

    b.dispose()
    a.dispose() # safe no-op on the moved-from value

  test "works with a custom key type and hash":
    var t = SharedTable[Key, int].init()
    t.put(Key(v: 1), 100)
    t.put(Key(v: 2), 200)

    check:
      t.get(Key(v: 1)) == Opt.some(100)
      t.get(Key(v: 2)) == Opt.some(200)
      not t.contains(Key(v: 3))
    t.dispose()

suite "SharedBytes Tests":

  test "init and data round-trip non-empty bytes":
    let input = @[1'u8, 2, 3, 4, 5]
    var sb = SharedBytes.init(input)
    check sb.data() == input
    dispose(sb)

  test "init from an array literal":
    var sb = SharedBytes.init([10'u8, 20, 30])
    check sb.data() == @[10'u8, 20, 30]
    dispose(sb)

  test "init from an empty seq yields an empty SharedBytes":
    var sb = SharedBytes.init(newSeq[byte]())
    check:
      sb.data(asOpenArray = true).len == 0
      sb.data(asOpenArray = false).len == 0
    dispose(sb)

  test "data (asOpenArray = true) exposes a matching read-only view":
    let input = @[7'u8, 8, 9, 10]
    var sb = SharedBytes.init(input)
    check:
      sb.data(asOpenArray = true).len == input.len
      @(sb.data(asOpenArray = true)) == input
      sb.data(asOpenArray = true)[0] == 7'u8
      sb.data(asOpenArray = true)[3] == 10'u8
    dispose(sb)

  test "init copies the input, leaving SharedBytes independent of the source":
    var input = @[1'u8, 2, 3]
    var sb = SharedBytes.init(input)

    # Mutating and even clearing the source must not affect the copy.
    input[0] = 99
    input.setLen(0)

    check sb.data() == @[1'u8, 2, 3]
    dispose(sb)

  test "preserves embedded zero bytes":
    let input = @[0'u8, 1, 0, 2, 0, 0, 3, 0]
    var sb = SharedBytes.init(input)
    check sb.data() == input
    dispose(sb)

  test "round-trips large binary data":
    var input = newSeq[byte](100_000)
    for i in 0 ..< input.len:
      input[i] = byte(i and 0xFF)
    var sb = SharedBytes.init(input)
    check:
      sb.data.len == input.len
      sb.data() == input
    dispose(sb)

  test "dispose frees, resets and is idempotent":
    var sb = SharedBytes.init(@[1'u8, 2, 3])

    dispose(sb)
    check:
      sb.data().len == 0
      sb.data.len == 0

    dispose(sb) # second dispose must be a safe no-op
    check sb.data().len == 0

  test "move transfers ownership and clears the source":
    var a = SharedBytes.init(@[10'u8, 20, 30])
    var b = move(a)

    check:
      b.data() == @[10'u8, 20, 30]
      a.data().len == 0 # the moved-from value is reset

    dispose(b)
    dispose(a) # safe no-op on the moved-from value
