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

import std/sequtils, unittest2, ../../execution_chain/concurrency/lru

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

suite "ConcurrentLruCache Tests":

  test "small":
    var lru = ConcurrentLruCache[int, int].init(0)
    # lru.init(0)

    lru.put(0, 0)
    check:
      not lru.contains(0)

    lru.put(1, 1)
    check:
      not lru.contains(1)

    lru.capacity = 1

    lru.put(1, 1)
    check:
      lru.contains(1)
      not lru.contains(0)

    lru.del(1)
    check:
      not lru.contains(1)
      not lru.contains(0)

    lru.put(2, 2)
    check:
      lru.contains(2)
      not lru.contains(1)
      not lru.contains(0)

    lru.put(3, 3)
    check:
      lru.contains(3)
      not lru.contains(2)
      not lru.contains(0)

    lru.capacity = 2
    lru.put(4, 4)
    check:
      lru.contains(4)
      lru.contains(3)
      not lru.contains(2)
      not lru.contains(0)
      toSeq(lru.keys()) == @[4, 3]

    lru.del(3)
    lru.del(4)

    check:
      not lru.contains(4)
      not lru.contains(3)
      not lru.contains(2)
      not lru.contains(0)

  test "simple ops":
    var lru = ConcurrentLruCache[int, int].init(10)
    
    for i in 0 ..< 10:
      for (evicted, _, _) in lru.putWithEvicted(i, i):
        check false # All are new items so we shouldn't be iterating over

      check:
        lru.contains(i)

    check:
      not lru.update(100, 100)
      not lru.refresh(100, 100)

    lru.del(5)

    check:
      not lru.contains(5)

    # should take the spot of 5
    for (evicted, _, _) in lru.putWithEvicted(11, 11):
      check false # Also not a new spot

    check:
      lru.contains(0)
      lru.contains(11)

      lru.update(1, 100)
      lru.refresh(0, 101)

      lru.contains(1)
      lru.get(1) == Opt.some(100)
      lru.peek(0) == Opt.some(101)

    for (evicted, key, _) in lru.putWithEvicted(12, 12):
      check:
        evicted
        key == 0

    check:
      not lru.contains(0) # 0 was added first, 11 took 5's place
      lru.contains(1)

    lru.put(13, 13)

    check:
      not lru.contains(2) # 1 should have been shifted to front
      lru.contains(1)

    check:
      lru.peek(3) == Opt.some(3)

    lru.put(14, 14)
    check:
      not lru.contains(3) # peek should not reorder

    lru.put(4, 44)
    check:
      lru.peek(4) == Opt.some(44)

    lru.put(15, 15)
    check:
      lru.contains(4)
      not lru.contains(6)

    check:
      lru.pop(4) == Opt.some(44)
      lru.pop(15) == Opt.some(15)
      lru.pop(4) == Opt.none(int)
      lru.pop(15) == Opt.none(int)
      not lru.contains(4)
      not lru.contains(15)

  test "growth by 1":
    var lru = ConcurrentLruCache[int, int].init(0)

    for i in 0 ..< 200000:
      lru.capacity = i + 1
      lru.put(i, i)
      check lru.contains(i)

    # LRU order is inverse
    block:
      var i = 200000
      for k in lru.keys:
        i -= 1
        check:
          i == k

    for i in 0 ..< 200000:
      lru.del(i)

    for i in 0 ..< 200001:
      # No growth
      lru.put(i, i)
      check lru.contains(i)

    check:
      not lru.contains(0)
      lru.contains(1)

  test "direct growth":
    var lru = ConcurrentLruCache[int, int].init(200000)

    for i in 0 ..< 200000:
      lru.put(i, i)
      check lru.contains(i)

    for i in 0 ..< 200001:
      # No growth
      for (evicted, key, value) in lru.putWithEvicted(i, i):
        check:
          not evicted or (i == 200000 and value == 0)
      check lru.contains(i)

    check:
      not lru.contains(0)
      lru.contains(1)

  test "heterogenous lookup":
    var lru = ConcurrentLruCache[A, int].init(10)

    lru.put(A(v: 10), 10)

    check:
      lru.contains(B(v: 10))

  test "readme example":
    # Create cache that holds up to 2 items
    var lru = ConcurrentLruCache[int, int].init(2)

    lru.put(10, 10)
    lru.put(20, 20)

    assert lru.get(10) == Opt.some(10)

    lru.put(30, 30)

    # 10 was more recent
    assert lru.get(20).isNone()

    # Allow capacity to grow to 3 items if needed
    lru.capacity = 3

    # Accessed to evicted 20
    for (evicted, key, value) in lru.putWithEvicted(40, 40):
      assert evicted and key == 20

    assert lru.get(20).isNone()

  test "iterating over evicted items":
    var lru = ConcurrentLruCache[int, int].init(2)

    lru.put(10, 11)
    lru.put(20, 22)

    var found1, found2: bool
    # Update existing value
    for (evicted, key, value) in lru.putWithEvicted(10, 15):
      check:
        not found1
        not evicted
        key == 10
        value == 11
      found1 = true

    check:
      found1
      lru.peek(10) == Opt.some(15)

    # Evict to make room for new item
    for (evicted, key, value) in lru.putWithEvicted(30, 33):
      check:
        not found2
        evicted
        key == 20
        value == 22 # Last accessed, now that 10 was updated
      found2 = true
    check:
      found2

  test "MRU iteration order":
    var lru = ConcurrentLruCache[int, int].init(5)

    for i in 0 ..< 6:
      lru.put(i, i)

    check:
      toSeq(lru.keys()) == @[5, 4, 3, 2, 1]