# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

# The LruCache type below is a modified copy of the minilru cache. It is not
# thread-safe but has been modified to remove the usage of the seq type and
# replaces the nodes and buckets lists with UncheckedArrays which are allocated
# on the shared heap. This is needed to support multi-threaded use cases when
# using refc.

{.push raises: [], gcsafe.}

import std/[atomics, cpuinfo, hashes, math, typetraits], results, ./readwritelock

export hashes, results

type
  LruNode[K, V] = tuple[next, prev: uint32, key: K, value: V]

  LruBucket = tuple[subhash: uint32, index: uint32]

  LruCache[K, V] = object
    ## Efficient implementation of classic LRU cache with a tightly packed
    ## doubly-linked list and robin-hood style hash table.
    ##
    ## The list links, keys and values are stored in a contiguous `seq` with
    ## links being `uint32` indices - as a consequence, capacity is capped at
    ## 2**32 entries even on 64-bit platforms.
    ##
    ## The table similarly maps hashes to indices resulting in a tight packing
    ## for the buckets and low memory overhead. Robin-hood open addressing is
    ## used for resolving collisions.
    ##
    ## Overhead at roughly 18-20 bytes per item in addition to storage for key
    ## and value - `8` for the linked list and `(8/0.8 + rounding)` for hash
    ## buckets.
    ##
    ## Items are moved to the front on access and add and evicted from the back
    ## when full.
    ##
    ## The table supports heterogenous lookups, ie using a different key type
    ## than is assigned to the table. When doing so, the types must be
    ## comparable for both equality (`==`) and hash (`hash`).
    ##
    ## Robin-hood hashing:
    ## * https://cs.uwaterloo.ca/research/tr/1986/CS-86-14.pdf
    ## * https://codecapsule.com/2013/11/11/robin-hood-hashing/
    ## * https://programming.guide/robin-hood-hashing.html
    ##
    ## The layout of the LRU node list was inspired by:
    ## * https://github.com/phuslu/lru
    ## * https://github.com/goossaert/hashmap
    ##
    ## Limitations:
    ##
    ## Because the "last used item" is not explicitly tracked, it's also not
    ## possible to pop it without a lengthy iteration (for a non-full cache).
    nodes: ptr UncheckedArray[LruNode[K, V]]
    nodesAllocatedLen: int
    nodesLen: int
      ## Doubly-linked list of cached entries - 0-eth entry contains head/tail -
      ## this also allows using index 0 as a special marker for "unused" in the
      ## hash table

    buckets: ptr UncheckedArray[LruBucket]
    bucketsLen: int
      # Bucket list for robin-hood-style hash table with a capacity slightly
      # larger than the data list

    capacity: int ## Maximum capacity before we start evicting items
    used: int ## Number of entries currently in use

const fillRatio = 0.8

template targetLen(i: int): int =
  # Similar growth strategy as `seq` itself - the 1.5 value is common in growth
  # strategies due to it being close to the golden ratio which ends up working
  # better in cases where the seq has to be grown multiple times in which case
  # it leaves behind chunks that when put together in theory can fit the "next"
  # seq: https://github.com/facebook/folly/blob/main/folly/docs/FBVector.md#memory-handling
  # TODO investigate whether the default nim allocator works this way too..
  if i < 8:
    16
  elif i < 32768:
    65536
  else:
    (i * 3) div 2

template toSubhash(h: Hash): uint32 =
  # Hashes will be masked by an uint32 value so we might as well reduce the
  # incoming hash value and save some memory - this might cost a few key
  # comparisons on collisions but the effect should be tiny
  when sizeof(h) == sizeof(uint32):
    uint32(h)
  else:
    static:
      assert sizeof(h) == sizeof(uint64)
    let hh = h
    uint32(hh) + uint32(uint64(hh) shr 32)

template subhash(value: auto): uint32 =
  mixin hash
  hash(value).toSubhash()

proc moveToFront(s: var LruCache, i: uint32) =
  let first = s.nodes[0].next

  if first == i:
    return

  let nodei = addr s.nodes[i]

  s.nodes[nodei[].prev].next = nodei[].next
  s.nodes[nodei[].next].prev = nodei[].prev

  nodei[].prev = 0
  nodei[].next = first

  s.nodes[0].next = i
  s.nodes[first].prev = i

proc moveToBack(s: var LruCache, i: uint32) =
  let last = s.nodes[0].prev

  if last == i:
    return

  let nodei = addr s.nodes[i]

  s.nodes[nodei[].prev].next = nodei[].next
  s.nodes[nodei[].next].prev = nodei[].prev

  nodei[].prev = last
  nodei[].next = 0

  s.nodes[last].next = i
  s.nodes[0].prev = i

template lenu32(s: openArray[LruBucket]): uint32 =
  uint32(s.len)

iterator pairsAt(s: openArray[LruBucket], bucket: uint32): (uint32, LruBucket) =
  let mask = s.lenu32 - 1 # len must be power of two
  var i = bucket and mask

  while true: # The assumption is that the one calling breaks iteration
    yield (i, s[i])
    i = (i + 1) and mask

iterator mpairsAt(
    s: var openArray[LruBucket], bucket: uint32
): (uint32, var LruBucket) =
  let mask = s.lenu32 - 1 # len must be power of two
  var i = bucket and mask

  while true: # The assumption is that the one calling breaks iteration
    yield (i, s[i])
    i = (i + 1) and mask

template psl(buckets, bucket, subhash: uint32): uint32 =
  # distance from expected location aka probe sequence length
  let mask = buckets - 1
  # power-of-two mask and uint32 wrap-around ensures that even on underflow, the
  # result is well defined
  (bucket - subhash) and mask

proc tablePut(s: var openArray[LruBucket], subhash, index: uint32) =
  var
    subhash = subhash
    index = index
    dist = 0'u32

  for bi, b in s.mpairsAt(subhash):
    if b.index == 0:
      # We're guaranteed to find a bucket since the bucket list is longer than
      # the nodes list
      b.subhash = subhash
      b.index = index
      break

    let bdist = psl(s.lenu32, bi, b.subhash)

    if (dist > bdist):
      # insert item at minimum psl, shifting everything else forwards
      swap(b.subhash, subhash)
      swap(b.index, index)
      dist = bdist

    dist += 1

func tableBucket(s: LruCache, subhash: uint32, key: auto): Opt[uint32] =
  mixin `==`

  var dist: uint32
  for bi, b in toOpenArray(s.buckets, 0, s.bucketsLen - 1).pairsAt(subhash):
    let bdist = psl(s.bucketsLen.uint32, bi, b.subhash)
    if b.index == 0 or dist > bdist:
      break

    if b.subhash == subhash and s.nodes[b.index].key == key:
      return Opt.some(bi)
    dist += 1

template tableBucket(s: LruCache, key: auto): Opt[uint32] =
  s.tableBucket(subhash(key), key)

func tableGet(s: LruCache, subhash: uint32, key: auto): Opt[uint32] =
  if s.used == 0:
    Opt.none(uint32)
  else:
    let bucket = ?s.tableBucket(subhash, key)

    Opt.some(s.buckets[bucket].index)

template tableGet(s: LruCache, key: auto): Opt[uint32] =
  s.tableGet(subhash(key), key)

proc tableDel(s: var openArray[LruBucket], idx: uint32) =
  let mask = s.lenu32 - 1
  # Shift other items backward to fill the spot
  for bi, b in s.mpairsAt(idx):
    let
      ni = (bi + 1) and mask
      next = addr s[ni]

    if next[].index == 0:
      b.index = 0
      break

    let distance = psl(s.lenu32, ni, next[].subhash)
    if distance == 0:
      # When the "next" item is already in its expected bucket we introduce an
      # empty slot and stop
      b.index = 0
      break

    b = next[]

proc tableDel(s: var LruCache, subhash: uint32, key: auto): Opt[uint32] =
  # Find bucket with item-to-delete
  let
    bucket = ?s.tableBucket(subhash, key)
    idx = s.buckets[bucket].index

  toOpenArray(s.buckets, 0, s.bucketsLen - 1).tableDel(bucket)
  ok(idx)

template tableDel(s: var LruCache, key: auto): Opt[uint32] =
  s.tableDel(subhash(key), key)

proc grow[K, V](v: var LruCache[K, V], newSize: uint32) =
  doAssert newSize.int <= v.capacity + 1

  let oldSize = v.nodesLen.uint32

  if oldSize >= newSize or newSize <= 1:
    return

  if newSize.int > v.nodesAllocatedLen:
    # Grow by powers of two, but cap at capacity + 1 so the allocation never
    # exceeds what the cache can actually use.
    let allocSize = min(nextPowerOfTwo(newSize.int), v.capacity + 1)
    if v.nodes.isNil():
      v.nodes =
        cast[ptr UncheckedArray[LruNode[K, V]]](createShared(LruNode[K, V], allocSize))
    else:
      v.nodes = cast[ptr UncheckedArray[LruNode[K, V]]](resizeShared(
        v.nodes[0].addr, allocSize
      ))
    v.nodesLen = newSize.int
    v.nodesAllocatedLen = allocSize
  else:
    v.nodesLen = newSize.int

  # Create fully linked list of items - this keeps the move logic free of
  # special cases for uninitialized nodes
  for i in oldSize ..< newSize:
    v.nodes[i].next = uint32((i + 1) mod newSize)
    v.nodes[i].prev = uint32((i + newSize - 1) mod newSize)

  if oldSize > 0:
    # Adjust tail to point to end of newly allocated part
    v.nodes[oldSize].prev = v.nodes[0].prev
    v.nodes[v.nodes[0].prev].next = oldSize
    v.nodes[0].prev = newSize - 1

  let newTableSize = nextPowerOfTwo(int(ceil(newSize.float / fillRatio)))
  if v.bucketsLen >= newTableSize: # nextPowerOfTwo rounds up effectively..
    return

  let buckets = v.buckets
  v.buckets = cast[ptr UncheckedArray[LruBucket]](createShared(LruBucket, newTableSize))

  for i in 0 ..< v.bucketsLen:
    let b = buckets[i]
    if b.index != 0:
      toOpenArray(v.buckets, 0, newTableSize - 1).tablePut(b.subhash, b.index)

  if v.bucketsLen > 0:
    deallocShared(buckets)

  v.bucketsLen = newTableSize

proc init[K, V](T: type LruCache[K, V], capacity: int, initialSize: int = 0): T =
  ## Create a cache with the given capacity. If `initialSize` > 0, eagerly
  ## allocate space for that many entries up front to reduce the number of
  ## grow reallocations as the cache fills.
  static:
    doAssert supportsCopyMem(K), "K must be a non-GC type"
    doAssert supportsCopyMem(V), "V must be a non-GC type"
  doAssert initialSize <= capacity, "initialSize must not exceed capacity"
  result.capacity = capacity
  if initialSize > 0:
    result.grow(uint32(initialSize + 1))

proc dispose(s: var LruCache) =
  if s.nodesLen > 0:
    deallocShared(s.nodes)
    s.nodes = nil
    s.nodesLen = 0
    s.nodesAllocatedLen = 0
    s.used = 0

  if s.bucketsLen > 0:
    deallocShared(s.buckets)
    s.buckets = nil
    s.bucketsLen = 0

proc `=copy`[K, V](
    dest: var LruCache[K, V], src: LruCache[K, V]
) {.error: "Copying LruCache is forbidden".} =
  discard

when false:
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

  iterator values(s: var LruCache, mru: static bool = false): lent LruCache.V =
    ## Values in MRU order - starting from the front with the item that was most
    ## recently added or accessed.
    for index in s.mruIndices:
      yield s.nodes[index].value

  iterator mvalues(s: var LruCache, mru: static bool = false): var LruCache.V =
    ## Values in MRU order - starting from the front with the item that was most
    ## recently added or accessed.
    for index in s.mruIndices:
      yield s.nodes[index].value

  iterator pairs(
      s: var LruCache, mru: static bool = false
  ): (lent LruCache.K, lent LruCache.V) =
    ## Key/value pairs in MRU order - starting from the front with the item that
    ## was most recently added or accessed.
    for index in s.mruIndices:
      yield (s.nodes[index].key, s.nodes[index].value)

  iterator mpairs(
      s: var LruCache, mru: static bool = false
  ): (lent LruCache.K, var LruCache.V) =
    ## Key/value pairs in MRU order - starting from the front with the item that
    ## was most recently added or accessed.
    for index in s.mruIndices:
      yield (s.nodes[index].key, s.nodes[index].value)

  template `capacity=`(s: var LruCache, c: int) =
    ## Update the capacity (but don't reallocate the currenty cache). If the
    ## capacity is smaller than the currently allocated size, it will be ignored.
    s.capacity = c

template capacity(s: var LruCache): int =
  s.capacity

template len(s: var LruCache): int =
  int(s.used)

template contains(s: var LruCache, subhash: uint32, key: auto): bool =
  s.used > 0 and s.tableBucket(subhash, key).isSome()

template contains(s: var LruCache, key: auto): bool =
  ## Return true iff key can be found in cache - does not update item position
  s.contains(subhash(key), key)

proc del(s: var LruCache, subhash: uint32, key: auto): bool {.discardable.} =
  ## Returns true if an item was actually removed from the cache.
  if s.used == 0:
    return false

  let index = s.tableDel(subhash, key).valueOr:
    return false

  s.moveToBack(index)
  s.used -= 1
  true

template del(s: var LruCache, key: auto) =
  ## Remove item from cache, if present - does nothing if it was missing
  s.del(subhash(key), key)

proc pop[K, V](s: var LruCache[K, V], subhash: uint32, key: auto): Opt[V] =
  if s.used == 0:
    return Opt.none(V)

  let index = s.tableDel(subhash, key).valueOr:
    return Opt.none(V)

  result = Opt.some(move(s.nodes[index].value))

  s.moveToBack(index)
  s.used -= 1

template pop[K, V](s: var LruCache[K, V], key: auto): Opt[V] =
  ## Retrieve item and remove it from LRU cache
  s.pop(subhash(key), key)

proc get[K, V](s: var LruCache[K, V], subhash: uint32, key: auto): Opt[V] =
  let index = ?s.tableGet(subhash, key)
  s.moveToFront(index)
  result = Opt.some(s.nodes[index].value)

template get[K, V](s: var LruCache[K, V], key: auto): Opt[V] =
  ## Retrieve item and move it to the front of the LRU cache
  s.get(subhash(key), key)

func peek[K, V](s: var LruCache[K, V], subhash: uint32, key: auto): Opt[V] =
  let index = ?s.tableGet(subhash, key)
  result = Opt.some(s.nodes[index].value)

template peek[K, V](s: var LruCache[K, V], key: auto): Opt[V] =
  ## Retrieve item without moving it to the front
  s.peek(subhash(key), key)

proc getPtr[K, V](s: var LruCache[K, V], subhash: uint32, key: auto): ptr V =
  ## Pointer to the value, moving the item to the front - nil if not found
  let index = s.tableGet(subhash, key).valueOr:
    return nil
  s.moveToFront(index)
  addr s.nodes[index].value

template getPtr[K, V](s: var LruCache[K, V], key: auto): ptr V =
  ## Pointer to the value, moving the item to the front - nil if not found
  s.getPtr(subhash(key), key)

func peekPtr[K, V](s: var LruCache[K, V], subhash: uint32, key: auto): ptr V =
  ## Pointer to the value without moving the item - nil if not found
  let index = s.tableGet(subhash, key).valueOr:
    return nil
  addr s.nodes[index].value

proc moveToFront(s: var LruCache, subhash: uint32, key: auto) =
  ## Look up the item by key and move it to the front of the LRU cache - does
  ## nothing if the key is not present. Unlike `get`, no value is copied out.
  let index = s.tableGet(subhash, key).valueOr:
    return
  s.moveToFront(index)

proc update(s: var LruCache, subhash: uint32, key: auto, value: auto): bool =
  let index = s.tableGet(subhash, key).valueOr:
    return false

  s.nodes[index].value = value
  s.moveToFront(index)
  result = true

template update(s: var LruCache, key: auto, value: auto): bool =
  ## Update and move an existing item to the front of the LRU cache - returns
  ## true if the item was updated, false if it was not in the cache
  s.update(subhash(key), key, value)

proc refresh(s: var LruCache, subhash: uint32, key: auto, value: auto): bool =
  let index = s.tableGet(subhash, key).valueOr:
    return false

  s.nodes[index].value = value
  result = true

template refresh(s: var LruCache, key: auto, value: auto): bool =
  ## Update existing item without moving it to the front of the LRU cache -
  ## returns true if the item was refreshed, false if it was not in the cache
  s.refresh(subhash(key), key, value)

iterator putWithEvicted[K, V](
    s: var LruCache, subhash: uint32, key: K, value: V
): tuple[evicted: bool, key: LruCache.K, value: LruCache.V] =
  if s.used + 1 >= s.nodesLen:
    s.grow(uint32(min(s.capacity, targetLen(s.used)) + 1))

  if s.nodesLen > 0: # if capacity was 0, there will be no growth
    let
      bucket = s.tableBucket(subhash, key)

      index =
        if bucket.isSome(): # Replacing an existing item
          let index = s.buckets[bucket[]].index
          yield (false, s.nodes[index].key, s.nodes[index].value)

          s.nodes[index].value = value
          index
        else:
          let
            last = s.nodes[0].prev
            node = addr s.nodes[last]
            evicted = s.tableBucket(node[].key)

          # Evict the least recently used item from the lookup table - the bucket
          # comparison avoids a false positive which happens when the last node holds
          # a default-initialized key (or a key that has not been cleared during
          # `del`) but that key currently has been assigned elsewhere
          if evicted.isSome():
            let index = s.buckets[evicted[]].index

            if index == last:
              # Evict the tail (instead of updating it)
              yield (true, s.nodes[index].key, s.nodes[index].value)
              toOpenArray(s.buckets, 0, s.bucketsLen - 1).tableDel(evicted[])
            else:
              s.used += 1
          else:
            s.used += 1

          node[].key = key
          node[].value = value

          toOpenArray(s.buckets, 0, s.bucketsLen - 1).tablePut(subhash, last)
          last

    s.moveToFront(index)

iterator putWithEvicted[K, V](
    s: var LruCache, key: K, value: V
): tuple[evicted: bool, key: LruCache.K, value: LruCache.V] =
  ## Insert a new item in the cache, replacing the least recently used one and
  ## yielding the updated or evicted item(s), if any, with their pre-put value.
  ##
  ## Note: Although the API supports evicting more than one item, currently this
  ## cannot cannot happen - future versions may include options for evaluating
  ## the cost of each item at which point several "cheap" items may get evicted
  ## when an expensive item is added.
  for v in s.putWithEvicted(subhash(key), key, value):
    yield v

proc put(
    s: var LruCache, subhash: uint32, key: auto, value: auto
): bool {.discardable.} =
  ## Returns true if `s.len` increased (a new entry occupied a free slot), false
  ## if the put replaced an existing entry or evicted the LRU item.
  if s.used + 1 >= s.nodesLen:
    s.grow(uint32(min(s.capacity, targetLen(s.used)) + 1))

  if s.nodesLen == 0:
    return false # capacity was 0, nothing to do

  let bucket = s.tableBucket(subhash, key)
  if bucket.isSome():
    # Replacing an existing item - no need to read old key/value
    let index = s.buckets[bucket[]].index
    s.nodes[index].value = value
    s.moveToFront(index)
    return false

  # Inserting a new item, reusing the tail slot
  let last = s.nodes[0].prev
  if s.used + 1 < s.nodesLen:
    # Below capacity - tail is a free slot (freshly grown or previously
    # deleted), no eviction needed.
    s.used += 1
    result = true
  else:
    # At capacity - tail holds the LRU item; evict it from the lookup table.
    let evicted = s.tableBucket(s.nodes[last].key)
    if evicted.isSome() and s.buckets[evicted[]].index == last:
      toOpenArray(s.buckets, 0, s.bucketsLen - 1).tableDel(evicted[])
      # result stays false: one evicted, one inserted, net length unchanged
    else:
      s.used += 1
      result = true

  let node = addr s.nodes[last]
  node[].key = key
  node[].value = value

  toOpenArray(s.buckets, 0, s.bucketsLen - 1).tablePut(subhash, last)
  s.moveToFront(last)

template put(s: var LruCache, key: auto, value: auto) =
  ## Insert or update an item in the cache, replacing the least recently used
  ## one if inserting the item would exceed capacity.
  s.put(subhash(key), key, value)

# ConcurrentLruCache is a thread safe LRU cache designed to handle high
# throughput concurrent reads and writes from multiple threads. It uses a
# sharded design in order to mitigate contention and internally uses a
# LRU cache (not thread-safe) in each shard. Each shard has a dedicated lock
# to allow for concurrent access. Shards are picked using the high bits of the
# key's hash while the LruCache inside each shard picks buckets from the low
# bits of the (folded) hash - keeping the two bit ranges disjoint avoids any
# correlation between shard and bucket placement.
#
# This sharded implementation performs badly for the single threaded scenario
# so as a temporary workaround we use a case object and based on the threadSafe
# flag, branch to using the non-thread safe LruCache (when threadSafe = false)
# without the locking. Eventually we will implement a more optimised ConcurrentLruCache
# that performs better for both scenarios using the same code paths.

const
  CACHE_LINE_SIZE = when defined(macosx) and defined(arm64): 128 else: 64
  SAMPLE_MASK = 15'u32

var tlsLruGetCounter {.threadvar.}: uint32

type
  State {.pure.} = enum
    UNINITIALIZED
    INITIALIZED
    DISPOSED

  Shard[K, V] = object
    lock {.align: CACHE_LINE_SIZE.}: ReadWriteLock
    cache: LruCache[K, V]
    usedCount {.align: CACHE_LINE_SIZE.}: Atomic[int]

  ConcurrentLruCache*[K, V] = object
    state: State
    case threadSafe: bool
    of true:
      shards: ptr UncheckedArray[Shard[K, V]]
      shardBits: int
    of false:
      cache: LruCache[K, V]

func defaultShardBits*(cpuCount: int): int =
  # Default shard count of roughly 4 * cpuCount, rounded up to the nearest
  # power of two. e.g. cpuCount = 16 -> 64 shards (shardBits = 6).
  let target = min(max(cpuCount, 1), 16) * 4
  var bits = 1
  while (1 shl bits) < target:
    inc bits
  bits

template numShards(shardBits: int): int =
  1 shl shardBits

template numShards*[K, V](lru: ConcurrentLruCache[K, V]): int =
  if lru.threadSafe:
    numShards(lru.shardBits)
  else:
    1

proc init*[K, V](
    lru: var ConcurrentLruCache[K, V],
    capacity: int,
    initialSize: int = 0,
    shardBits: int = defaultShardBits(countProcessors()),
    threadSafe: bool = true,
) =
  # init is not thread safe and so the caller must ensure that no other threads
  # are using the cache while initialising it.
  static:
    doAssert supportsCopyMem(K), "K must be a non-GC type"
    doAssert supportsCopyMem(V), "V must be a non-GC type"
  doAssert lru.state == State.UNINITIALIZED
  doAssert shardBits >= 0 and shardBits <= 30
  doAssert initialSize <= capacity, "initialSize must not exceed capacity"
  if not threadSafe:
    doAssert shardBits == 0 # Enforce single shard for single threaded mode

  if threadSafe:
    let shardCount = numShards(shardBits)
    # per-shard capacity (ceiling div); total effective capacity is shardCapacity * shardCount
    let shardCapacity = (capacity + shardCount - 1) div shardCount
    let shardInitialSize = (initialSize + shardCount - 1) div shardCount
    let shards =
      cast[ptr UncheckedArray[Shard[K, V]]](createShared(Shard[K, V], shardCount))
    for i in 0 ..< shardCount:
      shards[i].cache = LruCache[K, V].init(shardCapacity, shardInitialSize)
      shards[i].lock.init()
      shards[i].usedCount.store(0, moRelaxed)
    lru = ConcurrentLruCache[K, V](
      state: State.INITIALIZED, threadSafe: true, shards: shards, shardBits: shardBits
    )
  else:
    lru = ConcurrentLruCache[K, V](
      state: State.INITIALIZED,
      threadSafe: false,
      cache: LruCache[K, V].init(capacity, initialSize),
    )

proc dispose*[K, V](lru: var ConcurrentLruCache[K, V]) =
  # dispose is not thread safe and so the caller must ensure that no other threads
  # are using the cache while disposing it.
  if lru.state == State.INITIALIZED:
    if lru.threadSafe:
      for i in 0 ..< lru.numShards():
        lru.shards[i].cache.dispose()
        lru.shards[i].lock.dispose()
      deallocShared(lru.shards)
      lru.shards = nil
    else:
      lru.cache.dispose()
    lru.state = State.DISPOSED

proc `=copy`[K, V](
    dest: var Shard[K, V], src: Shard[K, V]
) {.error: "Copying Shard is forbidden".} =
  discard

proc `=copy`*[K, V](
    dest: var ConcurrentLruCache[K, V], src: ConcurrentLruCache[K, V]
) {.error: "Copying ConcurrentLruCache is forbidden".} =
  discard

template toShardIdx(h: Hash, shardBits: int): int =
  # Pick the shard from the top shardBits bits of the hash so that the shard
  # selection bits do not overlap with the low bits that the LruCache uses for
  # bucket selection inside the shard.
  if shardBits == 0:
    0
  else:
    when sizeof(h) == sizeof(uint32):
      int(cast[uint32](h) shr (32 - shardBits))
    else:
      static:
        assert sizeof(h) == sizeof(uint64)
      int(cast[uint64](h) shr (64 - shardBits))

template withShardRead[K, V](
    lru: ConcurrentLruCache[K, V], key: K, body: untyped
): auto =
  let
    h = hash(key)
    sh {.inject.} = h.toSubhash()
    s {.inject.} = addr lru.shards[h.toShardIdx(lru.shardBits)]

  s.lock.lockRead()
  try:
    body
  finally:
    s.lock.unlockRead()

template withShardWrite[K, V](
    lru: ConcurrentLruCache[K, V], key: K, body: untyped
): auto =
  let
    h = hash(key)
    sh {.inject.} = h.toSubhash()
    s {.inject.} = addr lru.shards[h.toShardIdx(lru.shardBits)]

  s.lock.lockWrite()
  try:
    body
  finally:
    s.lock.unlockWrite()

template shardCapacity*[K, V](lru: var ConcurrentLruCache[K, V]): int =
  # No locking here because capacity is immutable for the ConcurrentLruCache type
  # and the internal LruCache type which does support updating the capacity, is
  # not exported.
  if lru.threadSafe:
    lru.shards[0].cache.capacity
  else:
    lru.cache.capacity

func shardLenForKey*[K, V](lru: var ConcurrentLruCache[K, V], key: K): int =
  if lru.threadSafe:
    let
      h = hash(key)
      s = addr lru.shards[h.toShardIdx(lru.shardBits)]
    s.usedCount.load(moRelaxed)
  else:
    lru.cache.len

template capacity*[K, V](lru: var ConcurrentLruCache[K, V]): int =
  lru.shardCapacity() * lru.numShards()

func len*[K, V](lru: var ConcurrentLruCache[K, V]): int =
  if lru.threadSafe:
    var total = 0
    for i in 0 ..< lru.numShards():
      total += lru.shards[i].usedCount.load(moRelaxed)
    total
  else:
    lru.cache.len

func contains*[K, V](lru: var ConcurrentLruCache[K, V], key: K): bool =
  if lru.threadSafe:
    withShardRead(lru, key):
      s.cache.contains(sh, key)
  else:
    lru.cache.contains(key)

func peek*[K, V](lru: var ConcurrentLruCache[K, V], key: K): Opt[V] =
  if lru.threadSafe:
    withShardRead(lru, key):
      s.cache.peek(sh, key)
  else:
    lru.cache.peek(key)

proc get*[K, V](lru: var ConcurrentLruCache[K, V], key: K): Opt[V] =
  if lru.threadSafe:
    let
      h = hash(key)
      sh = h.toSubhash()
      s = addr lru.shards[h.toShardIdx(lru.shardBits)]

    var value: Opt[V]
    s.lock.withReadLock:
      value = s.cache.peek(sh, key)

    if value.isSome():
      inc tlsLruGetCounter
      if (tlsLruGetCounter and SAMPLE_MASK) == 0'u32:
        s.lock.withWriteLock:
          s.cache.moveToFront(sh, key)
    value
  else:
    lru.cache.get(key)

func toLent[T](p: ptr T): lent T =
  # Borrow the pointee as a read-only view (no copy). Used to hand `withReadValue`
  # bodies access to the cached value without letting them mutate it - assigning
  # to a `lent` is a compile error.
  p[]

template withReadValue*[K, V](
    lru: var ConcurrentLruCache[K, V], key: K, value, body: untyped
) =
  mixin hash

  if lru.threadSafe:
    let
      h = hash(key)
      sh = h.toSubhash()
      s = addr lru.shards[h.toShardIdx(lru.shardBits)]
    var found = false

    s.lock.withReadLock:
      let valuePtr = s.cache.peekPtr(sh, key)
      if valuePtr != nil:
        found = true
        template value(): untyped {.inject.} = toLent(valuePtr)
        body

    if found:
      inc tlsLruGetCounter
      if (tlsLruGetCounter and SAMPLE_MASK) == 0'u32:
        s.lock.withWriteLock:
          s.cache.moveToFront(sh, key)
  else:
    let valuePtr = lru.cache.getPtr(key)
    if valuePtr != nil:
      template value(): untyped {.inject.} = toLent(valuePtr)
      body

template withReadValue*[K, V](
    lru: var ConcurrentLruCache[K, V], key: K, value, body1, body2: untyped
) =
  mixin hash

  if lru.threadSafe:
    let
      h = hash(key)
      sh = h.toSubhash()
      s = addr lru.shards[h.toShardIdx(lru.shardBits)]
    var found = false

    s.lock.withReadLock:
      let valuePtr = s.cache.peekPtr(sh, key)
      if valuePtr != nil:
        found = true
        template value(): untyped {.inject.} = toLent(valuePtr)
        body1

    if found:
      inc tlsLruGetCounter
      if (tlsLruGetCounter and SAMPLE_MASK) == 0'u32:
        s.lock.withWriteLock:
          s.cache.moveToFront(sh, key)
    else:
      body2
  else:
    let valuePtr = lru.cache.getPtr(key)
    if valuePtr != nil:
      template value(): untyped {.inject.} = toLent(valuePtr)
      body1
    else:
      body2

proc put*[K, V](lru: var ConcurrentLruCache[K, V], key: K, val: V) =
  if lru.threadSafe:
    withShardWrite(lru, key):
      if s.cache.put(sh, key, val):
        s.usedCount.store(s.cache.len, moRelaxed)
  else:
    lru.cache.put(key, val)

proc pop*[K, V](lru: var ConcurrentLruCache[K, V], key: K): Opt[V] =
  if lru.threadSafe:
    withShardWrite(lru, key):
      let r = s.cache.pop(sh, key)
      if r.isSome():
        s.usedCount.store(s.cache.len, moRelaxed)
      r
  else:
    lru.cache.pop(key)

proc update*[K, V](lru: var ConcurrentLruCache[K, V], key: K, val: V): bool =
  if lru.threadSafe:
    withShardWrite(lru, key):
      s.cache.update(sh, key, val)
  else:
    lru.cache.update(key, val)

proc refresh*[K, V](lru: var ConcurrentLruCache[K, V], key: K, val: V): bool =
  if lru.threadSafe:
    withShardWrite(lru, key):
      s.cache.refresh(sh, key, val)
  else:
    lru.cache.refresh(key, val)

proc del*[K, V](lru: var ConcurrentLruCache[K, V], key: K) =
  if lru.threadSafe:
    withShardWrite(lru, key):
      if s.cache.del(sh, key):
        s.usedCount.store(s.cache.len, moRelaxed)
  else:
    lru.cache.del(key)
