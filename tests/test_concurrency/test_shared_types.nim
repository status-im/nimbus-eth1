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

  # Every CollKey hashes to the same bucket, so a sequence of inserts forms a
  # single probe chain. Deleting from the middle of such a chain is what forces
  # the backward-shift path in `del` to actually move following entries.
  CollKey = object
    v: int

func hash(k: Key): Hash =
  Hash(k.v)

func hash(k: CollKey): Hash =
  Hash(0)

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

  test "getOrDefault returns the value when present or a default when absent":
    var t = SharedTable[int, int].init()
    t.put(1, 10)

    check:
      t.getOrDefault(1) == 10 # present
      t.getOrDefault(2) == 0 # absent -> default(int)
      t.getOrDefault(1, -1) == 10 # present ignores the supplied default
      t.getOrDefault(2, -1) == -1 # absent -> supplied default
      t.len == 1 # lookups never insert
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

  test "withValue runs the do-block branch only when the key is missing":
    var t = SharedTable[int, int].init()
    t.put(1, 10)

    # Present key: the first block runs (and can mutate through the pointer);
    # the do-block must not run.
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

    # Missing key: only the do-block runs.
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

suite "SharedTable with move-only values Tests":
  # These cover the documented purpose of SharedTable: holding move-only,
  # non-GC value types (SharedBytes, nested SharedTable) whose `=copy` is
  # forbidden. The table must move values internally and never copy them.

  test "stores and retrieves SharedBytes values via withValue":
    var t = SharedTable[int, SharedBytes].init()
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

    # withValue on a missing key must not run the body.
    var ranMissing = false
    t.withValue(99, v):
      ranMissing = true
    check not ranMissing

    # Caller owns value lifetimes: dispose each value before the table.
    for v in t.mvalues():
      dispose(v)
    t.dispose()

  test "put updates a SharedBytes value in place":
    var t = SharedTable[int, SharedBytes].init()
    t.put(1, SharedBytes.init([1'u8, 2, 3]))

    # Overwriting leaks the previous value unless the caller frees it first.
    t.withValue(1, v):
      dispose(v[])
    t.put(1, SharedBytes.init([9'u8, 9]))

    check t.len == 1
    var ok = false
    t.withValue(1, v):
      check v[].data() == @[9'u8, 9]
      ok = true
    check ok

    for v in t.mvalues():
      dispose(v)
    t.dispose()

  test "pop backward-shifts move-only values and transfers ownership":
    # All keys collide into one probe chain, so removing a middle key forces the
    # backward-shift to move the following entries back. This guards the `=copy`
    # fix that previously prevented removal from compiling for move-only values,
    # and checks that pop hands the removed value to the caller to dispose.
    var t = SharedTable[CollKey, SharedBytes].init()
    for i in 0 ..< 20:
      t.put(CollKey(v: i), SharedBytes.init([byte(i)]))
    check t.len == 20

    var removed = t.pop(CollKey(v: 5))
    check:
      removed.isSome()
      removed.unsafeGet().data() == @[byte(5)]
      t.len == 19
      not t.contains(CollKey(v: 5))
      t.pop(CollKey(v: 5)).isNone() # already gone
    removed.unsafeGet().dispose() # the caller now owns the popped value

    # Every surviving entry kept its correct bytes through the shift.
    for i in 0 ..< 20:
      if i == 5:
        check not t.contains(CollKey(v: i))
      else:
        var ok = false
        t.withValue(CollKey(v: i), v):
          check v[].data() == @[byte(i)]
          ok = true
        check ok

    for v in t.mvalues():
      dispose(v)
    t.dispose()

  test "pop does not leak move-only values":
    # Removing an owning value via pop (and disposing the result) must return all
    # shared memory; via del the value would be abandoned and leaked instead.
    let before = getOccupiedSharedMem()
    for _ in 0 ..< 100:
      var t = SharedTable[int, SharedBytes].init()
      t[1] = SharedBytes.init([1'u8, 2, 3, 4, 5, 6, 7, 8])
      t[2] = SharedBytes.init([9'u8, 9])
      var popped = t.pop(1)
      popped.unsafeGet().dispose()
      for v in t.mvalues():
        v.dispose()
      t.dispose()
    check getOccupiedSharedMem() == before

  test "holds nested SharedTable values":
    var outer = SharedTable[CollKey, SharedTable[int, int]].init()

    for i in 0 ..< 10:
      var inner = SharedTable[int, int].init()
      inner.put(i, i * 100)
      inner.put(i + 1000, i)
      outer.put(CollKey(v: i), move(inner))
    check outer.len == 10

    # Reach into a nested table through withValue.
    var innerLen = 0
    outer.withValue(CollKey(v: 3), inner):
      check inner[].get(3) == Opt.some(300)
      check inner[].get(1003) == Opt.some(3)
      innerLen = inner[].len
    check innerLen == 2

    # Delete a middle key: the colliding chain forces nested tables to be moved
    # by the backward-shift. Dispose the victim's memory first.
    outer.withValue(CollKey(v: 4), inner):
      inner[].dispose()
    check outer.del(CollKey(v: 4))
    check outer.len == 9

    # Surviving nested tables are intact after the shift.
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
