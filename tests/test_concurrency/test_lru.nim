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
  std/[importutils, sequtils],
  unittest2,
  taskpools,
  ../../execution_chain/concurrency/lru {.all.}

privateAccess(LruCache)
privateAccess(ConcurrentLruCache)
privateAccess(Shard)

iterator mruIndices(s: LruCache): uint32 =
  if s.nodesLen > 0:
    var pos = s.nodes[0].next
    for i in 0 ..< s.used:
      yield pos
      pos = s.nodes[pos].next

iterator keys(s: var LruCache): lent LruCache.K =
  ## Keys in MRU order - starting from the front with the item that was most
  ## recently added or accessed.
  for index in s.mruIndices:
    yield s.nodes[index].key

func allocatedNodes[K, V](s: LruCache[K, V]): int =
  s.nodesAllocatedLen

func allocatedBuckets[K, V](s: LruCache[K, V]): int =
  s.bucketsLen

func shardAllocatedNodes[K, V](lru: ConcurrentLruCache[K, V], i: int): int =
  if lru.threadSafe:
    lru.shards[i].cache.allocatedNodes
  else:
    lru.cache.allocatedNodes

func shardAllocatedBuckets[K, V](lru: ConcurrentLruCache[K, V], i: int): int =
  if lru.threadSafe:
    lru.shards[i].cache.allocatedBuckets
  else:
    lru.cache.allocatedBuckets

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

suite "LruCache Tests":
  test "small":
    var lru = LruCache[int, int].init(0)

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
    var lru = LruCache[int, int].init(10)

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
    var lru = LruCache[int, int].init(0)

    for i in 0 ..< 100000:
      lru.capacity = i + 1
      lru.put(i, i)
      check lru.contains(i)

    # LRU order is inverse
    block:
      var i = 100000
      for k in lru.keys:
        i -= 1
        check:
          i == k

    for i in 0 ..< 100000:
      lru.del(i)

    for i in 0 ..< 100001:
      # No growth
      lru.put(i, i)
      check lru.contains(i)

    check:
      not lru.contains(0)
      lru.contains(1)

  test "direct growth":
    var lru = LruCache[int, int].init(200000)

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

  test "initialSize preallocates":
    block: # initialSize == capacity: allocation is capped at capacity+1
      var lru = LruCache[int, int].init(1000, initialSize = 1000)
      defer:
        lru.dispose()

      check:
        lru.allocatedNodes == 1001
        lru.allocatedBuckets == 2048

      let nodesBefore = lru.allocatedNodes
      let bucketsBefore = lru.allocatedBuckets

      for i in 0 ..< 1000:
        lru.put(i, i)
      for i in 0 ..< 1000:
        check lru.contains(i)

      # No further grow during fill since initialSize == capacity
      check:
        lru.allocatedNodes == nodesBefore
        lru.allocatedBuckets == bucketsBefore

      lru.put(1000, 1000) # forces eviction of LRU (key 0)
      check:
        lru.len == 1000
        not lru.contains(0)
        lru.contains(1000)

    block: # initialSize < capacity: allocation rounded up to power of two
      var lru = LruCache[int, int].init(1000, initialSize = 100)
      defer:
        lru.dispose()

      check:
        lru.allocatedNodes == 128 # nextPowerOfTwo(101)
        lru.allocatedBuckets == 128 # nextPowerOfTwo(ceil(101/0.8))

      for i in 0 ..< 1000:
        lru.put(i, i)
      for i in 0 ..< 1000:
        check lru.contains(i)

      # Filling past initialSize forced reallocation up to the cap
      check lru.allocatedNodes == 1001

    block: # initialSize == 0 is the original lazy-allocation behaviour
      var lru = LruCache[int, int].init(1000)
      defer:
        lru.dispose()
      check:
        lru.allocatedNodes == 0
        lru.allocatedBuckets == 0

    block: # initialSize == 0 with capacity == 0 is a no-op
      var lru = LruCache[int, int].init(0, initialSize = 0)
      defer:
        lru.dispose()
      check lru.allocatedNodes == 0

  test "initialSize > capacity raises":
    expect Defect:
      discard LruCache[int, int].init(10, initialSize = 11)

  test "heterogenous lookup":
    var lru = LruCache[A, int].init(10)

    lru.put(A(v: 10), 10)

    check:
      lru.contains(B(v: 10))

  test "readme example":
    # Create cache that holds up to 2 items
    var lru = LruCache[int, int].init(2)

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
    var lru = LruCache[int, int].init(2)

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
    var lru = LruCache[int, int].init(5)

    for i in 0 ..< 6:
      lru.put(i, i)

    check:
      toSeq(lru.keys()) == @[5, 4, 3, 2, 1]

  test "moveToFront by key":
    var lru = LruCache[int, int].init(5)

    for i in 0 ..< 5:
      lru.put(i, i)
    check toSeq(lru.keys()) == @[4, 3, 2, 1, 0]

    # promote a key to the front (without copying its value out)
    lru.moveToFront(subhash(0), 0)
    check toSeq(lru.keys()) == @[0, 4, 3, 2, 1]

    # promoting the existing front is a no-op
    lru.moveToFront(subhash(0), 0)
    check toSeq(lru.keys()) == @[0, 4, 3, 2, 1]

    # a missing key leaves the order untouched
    lru.moveToFront(subhash(99), 99)
    check toSeq(lru.keys()) == @[0, 4, 3, 2, 1]

  test "dispose":
    block:
      var lru = LruCache[int, int].init(2)
      lru.dispose()

    block:
      var lru = LruCache[int, int].init(2)
      lru.put(10, 10)
      lru.put(20, 20)
      lru.dispose()

suite "ConcurrentLruCache Tests":
  test "defaultShardBits":
    # Smallest shardBits b such that (1 shl b) >= cpuCount * 4
    check:
      defaultShardBits(1) == 2 # 4 shards
      defaultShardBits(2) == 3 # 8 shards
      defaultShardBits(4) == 4 # 16 shards
      defaultShardBits(8) == 5 # 32 shards
      defaultShardBits(10) == 6 # 64 shards
      defaultShardBits(12) == 6 # 64 shards
      defaultShardBits(14) == 6 # 64 shards
      defaultShardBits(16) == 6 # 64 shards
      defaultShardBits(16) == 6 # 64 shards
      defaultShardBits(32) == 6 # 64 shards

  test "init and dispose":
    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(1000)
      lru.dispose()
      lru.reset()
      lru.init(1000)
      lru.dispose()

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(1000)
      lru.put(1, 1)
      lru.put(2, 2)
      lru.dispose()
      lru.reset()
      lru.init(1000)
      lru.put(1, 1)
      lru.put(2, 2)
      lru.dispose()

  test "put and get":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)
    lru.put(3, 30)

    check:
      lru.get(1) == Opt.some(10)
      lru.get(2) == Opt.some(20)
      lru.get(3) == Opt.some(30)
      lru.get(99) == Opt.none(int)

  test "put overwrites existing key":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(1, 20)

    check:
      lru.get(1) == Opt.some(20)
      lru.len() == 1

  test "pop":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)

    let val = lru.pop(1)

    check:
      val == Opt.some(10)
      not lru.contains(1)
      lru.get(1) == Opt.none(int)
      lru.contains(2)

  test "contains":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)

    check:
      lru.contains(1)
      not lru.contains(2)

  test "peek":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)

    check:
      lru.peek(1) == Opt.some(10)
      lru.peek(99) == Opt.none(int)

  test "withReadValue":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)

    var ran = false
    var seen = 0
    lru.withReadValue(1, v):
      ran = true
      seen = v # v is a read-only, zero-copy view of the stored value
    check:
      ran
      seen == 10

    # absent key: body must not run and no pointer is exposed
    ran = false
    lru.withReadValue(99, v):
      ran = true
    check not ran

  test "withReadValue and put with a precomputed hash":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    let
      key = 7
      keyHash = lru.toKeyHash(key)

    lru.putByHash(keyHash, key, 70) # insert using the precomputed hash

    var ran = false
    var seen = 0
    lru.withReadValueByHash(keyHash, key, v): # look up using the same hash
      ran = true
      seen = v
    check:
      ran
      seen == 70
      lru.peek(key) == Opt.some(70) # agrees with the hash-computing overloads

    # absent key: the body must not run
    ran = false
    lru.withReadValueByHash(lru.toKeyHash(8), 8, v):
      ran = true
    check not ran

  test "del":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)
    lru.del(1)

    check:
      not lru.contains(1)
      lru.get(1) == Opt.none(int)
      lru.contains(2)

    # del of missing key is a no-op
    lru.del(99)
    check lru.contains(2)

  test "update":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    check not lru.update(1, 100)

    lru.put(1, 10)

    check lru.update(1, 100)
    check lru.get(1) == Opt.some(100)

  test "refresh":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000)
    defer:
      lru.dispose()

    check not lru.refresh(1, 100)

    lru.put(1, 10)

    check lru.refresh(1, 100)
    check lru.peek(1) == Opt.some(100)

  test "len and capacity":
    var lru: ConcurrentLruCache[int, int]
    lru.init(640) # 10 per shard
    defer:
      lru.dispose()

    check:
      lru.len() == 0
      lru.capacity() == 640

    for i in 0 ..< 100:
      lru.put(i, i)

    check:
      lru.len() == 100
      lru.capacity() == 640

    for i in 0 ..< 100:
      lru.del(i)

    check:
      lru.len() == 0
      lru.capacity() == 640

  test "capacity calculation":
    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(0, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 0

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(63, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 64

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(64, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 64

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(65, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 128

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(127, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 128

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(128, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 128

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(129, shardBits = 6)
      defer:
        lru.dispose()
      check lru.capacity() == 192

  test "single shard":
    var lru: ConcurrentLruCache[int, int]
    lru.init(10, shardBits = 0)
    defer:
      lru.dispose()

    check:
      lru.numShards() == 1
      lru.shardCapacity() == 10
      lru.capacity() == 10

    for i in 0 ..< 10:
      lru.put(i, i * 10)

    check lru.len() == 10
    for i in 0 ..< 10:
      check lru.peek(i) == Opt.some(i * 10)
      # all entries land in the only shard regardless of hash
      check lru.shardLenForKey(i) == 10

    # exceeding capacity evicts one item; total size stays at capacity
    lru.put(100, 1000)
    check:
      lru.len() == 10
      lru.contains(100)

    lru.del(100)
    check:
      not lru.contains(100)
      lru.len() == 9

  test "shard info":
    var lru: ConcurrentLruCache[int, int]
    lru.init(640, shardBits = 6) # 10 per shard
    defer:
      lru.dispose()

    check:
      lru.numShards() == 64
      lru.shardCapacity() == 10
      lru.capacity() == 640

    for i in 0 ..< 64:
      check lru.shardLenForKey(i) == 0

  test "initialSize preallocates each shard":
    block: # initialSize == capacity: every shard preallocated to shardCapacity+1
      var lru: ConcurrentLruCache[int, int]
      lru.init(800, initialSize = 800, shardBits = 3) # 100 per shard
      defer:
        lru.dispose()

      for i in 0 ..< lru.numShards():
        check:
          lru.shardAllocatedNodes(i) == 101 # min(nextPowerOfTwo(101), 101)
          lru.shardAllocatedBuckets(i) == 128

    block: # initialSize < capacity: ceiling-divides per shard, rounded up
      var lru: ConcurrentLruCache[int, int]
      lru.init(800, initialSize = 80, shardBits = 3) # 10 per shard
      defer:
        lru.dispose()

      for i in 0 ..< lru.numShards():
        check:
          lru.shardAllocatedNodes(i) == 16 # nextPowerOfTwo(11)
          lru.shardAllocatedBuckets(i) == 16

    block: # initialSize == 0 leaves shards unallocated
      var lru: ConcurrentLruCache[int, int]
      lru.init(800, shardBits = 3)
      defer:
        lru.dispose()

      for i in 0 ..< lru.numShards():
        check:
          lru.shardAllocatedNodes(i) == 0
          lru.shardAllocatedBuckets(i) == 0

  test "initialSize > capacity raises":
    var lru: ConcurrentLruCache[int, int]
    expect Defect:
      lru.init(640, initialSize = 641, shardBits = 6)

  test "concurrent put, get, peek, del":
    const
      numThreads = 4
      keysPerThread = 500
      totalKeys = numThreads * keysPerThread

    var lru: ConcurrentLruCache[int, int]
    lru.init(totalKeys * 2) # headroom so eviction doesn't interfere
    defer:
      lru.dispose()
    let cachePtr = addr lru

    var tp = Taskpool.new(numThreads = numThreads)
    defer:
      tp.shutdown()

    proc tpPut(cache: ptr ConcurrentLruCache[int, int], base, count: int) =
      for i in 0 ..< count:
        cache[].put(base + i, base + i + 1) # value = key + 1

    proc tpGet(cache: ptr ConcurrentLruCache[int, int], base, count: int) =
      for i in 0 ..< count:
        discard cache[].get(base + i)

    proc tpPeek(cache: ptr ConcurrentLruCache[int, int], base, count: int) =
      for i in 0 ..< count:
        discard cache[].peek(base + i)

    proc tpDel(cache: ptr ConcurrentLruCache[int, int], base, count: int) =
      for i in 0 ..< count:
        cache[].del(base + i)

    # concurrent puts over disjoint key ranges
    for t in 0 ..< numThreads:
      tp.spawn tpPut(cachePtr, t * keysPerThread, keysPerThread)
    tp.syncAll()

    for i in 0 ..< totalKeys:
      check lru.get(i) == Opt.some(i + 1)

    # concurrent gets over disjoint key ranges
    for t in 0 ..< numThreads:
      tp.spawn tpGet(cachePtr, t * keysPerThread, keysPerThread)
    tp.syncAll()

    for i in 0 ..< totalKeys:
      check lru.peek(i) == Opt.some(i + 1)

    # concurrent peeks over disjoint key ranges
    for t in 0 ..< numThreads:
      tp.spawn tpPeek(cachePtr, t * keysPerThread, keysPerThread)
    tp.syncAll()

    for i in 0 ..< totalKeys:
      check lru.get(i) == Opt.some(i + 1)

    # mixed contention - writers and readers on the same full range
    for t in 0 ..< numThreads div 2:
      tp.spawn tpPut(cachePtr, 0, totalKeys)
    for t in 0 ..< numThreads div 2:
      tp.spawn tpGet(cachePtr, 0, totalKeys)
    tp.syncAll()

    # puts only update existing keys so all must still be present
    for i in 0 ..< totalKeys:
      check lru.contains(i)

    # concurrent peeks and puts on the same full range
    for t in 0 ..< numThreads div 2:
      tp.spawn tpPeek(cachePtr, 0, totalKeys)
    for t in 0 ..< numThreads div 2:
      tp.spawn tpPut(cachePtr, 0, totalKeys)
    tp.syncAll()

    for i in 0 ..< totalKeys:
      check lru.contains(i)

    # concurrent dels over disjoint key ranges
    for t in 0 ..< numThreads:
      tp.spawn tpDel(cachePtr, t * keysPerThread, keysPerThread)
    tp.syncAll()

    for i in 0 ..< totalKeys:
      check lru.get(i) == Opt.none(int)

    check lru.len() == 0

suite "ConcurrentLruCache Tests (threadSafe = false)":
  test "init and dispose":
    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(1000, shardBits = 0, threadSafe = false)
      lru.dispose()
      lru.reset()
      lru.init(1000, shardBits = 0, threadSafe = false)
      lru.dispose()

    block:
      var lru: ConcurrentLruCache[int, int]
      lru.init(1000, shardBits = 0, threadSafe = false)
      lru.put(1, 1)
      lru.put(2, 2)
      lru.dispose()
      lru.reset()
      lru.init(1000, shardBits = 0, threadSafe = false)
      lru.put(1, 1)
      lru.put(2, 2)
      lru.dispose()

  test "put and get":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)
    lru.put(3, 30)

    check:
      lru.get(1) == Opt.some(10)
      lru.get(2) == Opt.some(20)
      lru.get(3) == Opt.some(30)
      lru.get(99) == Opt.none(int)

  test "put overwrites existing key":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(1, 20)

    check:
      lru.get(1) == Opt.some(20)
      lru.len() == 1

  test "pop":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)

    let val = lru.pop(1)

    check:
      val == Opt.some(10)
      not lru.contains(1)
      lru.get(1) == Opt.none(int)
      lru.contains(2)
      lru.len() == 1

  test "contains":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)

    check:
      lru.contains(1)
      not lru.contains(2)

  test "peek":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)

    check:
      lru.peek(1) == Opt.some(10)
      lru.peek(99) == Opt.none(int)

  test "del":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)
    lru.del(1)

    check:
      not lru.contains(1)
      lru.get(1) == Opt.none(int)
      lru.contains(2)
      lru.len() == 1

    lru.del(99)
    check lru.contains(2)

  test "update":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    check not lru.update(1, 100)

    lru.put(1, 10)

    check lru.update(1, 100)
    check lru.get(1) == Opt.some(100)

  test "refresh":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    check not lru.refresh(1, 100)

    lru.put(1, 10)

    check lru.refresh(1, 100)
    check lru.peek(1) == Opt.some(100)

  test "len and capacity track internal cache":
    var lru: ConcurrentLruCache[int, int]
    lru.init(640, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    check:
      lru.len() == 0
      lru.capacity() == 640

    for i in 0 ..< 100:
      lru.put(i, i)

    check:
      lru.len() == 100
      lru.capacity() == 640

    for i in 0 ..< 100:
      lru.del(i)

    check:
      lru.len() == 0
      lru.capacity() == 640

  test "initialSize preallocates":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, initialSize = 1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    check:
      lru.shardAllocatedNodes(0) == 1001
      lru.shardAllocatedBuckets(0) == 2048

    let nodesBefore = lru.shardAllocatedNodes(0)
    let bucketsBefore = lru.shardAllocatedBuckets(0)

    for i in 0 ..< 1000:
      lru.put(i, i)
    for i in 0 ..< 1000:
      check lru.contains(i)

    check:
      lru.shardAllocatedNodes(0) == nodesBefore
      lru.shardAllocatedBuckets(0) == bucketsBefore

    lru.put(1000, 1000)
    check:
      lru.len() == 1000
      not lru.contains(0)
      lru.contains(1000)

  test "initialSize > capacity raises":
    var lru: ConcurrentLruCache[int, int]
    expect Defect:
      lru.init(1000, initialSize = 1001, shardBits = 0, threadSafe = false)

  test "single shard eviction":
    var lru: ConcurrentLruCache[int, int]
    lru.init(10, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    check:
      lru.numShards() == 1
      lru.shardCapacity() == 10
      lru.capacity() == 10

    for i in 0 ..< 10:
      lru.put(i, i * 10)

    check lru.len() == 10
    for i in 0 ..< 10:
      check lru.peek(i) == Opt.some(i * 10)
      check lru.shardLenForKey(i) == 10

    # exceeding capacity evicts the LRU item; total size stays at capacity
    lru.put(100, 1000)
    check:
      lru.len() == 10
      lru.contains(100)
      not lru.contains(0) # 0 was the LRU item

  test "get promotes on every access":
    var lru: ConcurrentLruCache[int, int]
    lru.init(3, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)
    lru.put(3, 30)

    # promote 1 to MRU on every get - inserting a new key must evict 2
    # (the actual LRU), not 1
    for _ in 0 ..< 5:
      check lru.get(1) == Opt.some(10)

    lru.put(4, 40)
    check:
      lru.contains(1)
      not lru.contains(2)
      lru.contains(3)
      lru.contains(4)

  test "withReadValue promotes and exposes a read-only view":
    var lru: ConcurrentLruCache[int, int]
    lru.init(3, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    lru.put(1, 10)
    lru.put(2, 20)
    lru.put(3, 30)

    # withReadValue promotes to MRU like get; inserting a new key must evict 2
    # (the actual LRU), not 1
    for _ in 0 ..< 5:
      var seen = 0
      lru.withReadValue(1, v):
        seen = v
      check seen == 10

    lru.put(4, 40)
    check:
      lru.contains(1)
      not lru.contains(2)
      lru.contains(3)
      lru.contains(4)

    # the view is read-only: assigning through it must not compile
    check not compiles(
      (block:
        lru.withReadValue(1, v):
          v = 111))

    # absent key: body must not run
    var ran = false
    lru.withReadValue(123, v):
      ran = true
    check not ran

  test "withReadValue and put with a precomputed hash":
    var lru: ConcurrentLruCache[int, int]
    lru.init(1000, shardBits = 0, threadSafe = false)
    defer:
      lru.dispose()

    let
      key = 7
      keyHash = lru.toKeyHash(key)

    lru.putByHash(keyHash, key, 70)

    var seen = 0
    lru.withReadValueByHash(keyHash, key, v):
      seen = v
    check:
      seen == 70
      lru.peek(key) == Opt.some(70)
