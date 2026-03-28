# minilru
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import std/[hashes, math, typetraits], results, ./readwritelock

export hashes, results

type
  LruNode[K, V] = tuple[next, prev: uint32, key: K, value: V]

  LruBucket = tuple[subhash: uint32, index: uint32]

  ConcurrentLruCache*[K, V] = object
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

    lock: ReadWriteLock

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

func moveToFront(s: var ConcurrentLruCache, i: uint32) =
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

func moveToBack(s: var ConcurrentLruCache, i: uint32) =
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

func tablePut(s: var openArray[LruBucket], subhash, index: uint32) =
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

func tableBucket(s: ConcurrentLruCache, subhash: uint32, key: auto): Opt[uint32] =
  mixin `==`

  var dist: uint32
  for bi, b in toOpenArray(s.buckets, 0, s.bucketsLen - 1).pairsAt(subhash):
    let bdist = psl(s.bucketsLen.uint32, bi, b.subhash)
    if b.index == 0 or dist > bdist:
      break

    if b.subhash == subhash and s.nodes[b.index].key == key:
      return Opt.some(bi)
    dist += 1

func tableBucket(s: ConcurrentLruCache, key: auto): Opt[uint32] =
  s.tableBucket(subhash(key), key)

func tableGet(s: ConcurrentLruCache, key: auto): Opt[uint32] =
  if s.used == 0:
    Opt.none(uint32)
  else:
    let bucket = ?s.tableBucket(key)

    Opt.some(s.buckets[bucket].index)

func tableDel(s: var openArray[LruBucket], idx: uint32) =
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

func tableDel(s: var ConcurrentLruCache, key: auto): Opt[uint32] =
  # Find bucket with item-to-delete
  let
    bucket = ?s.tableBucket(key)
    idx = s.buckets[bucket].index

  toOpenArray(s.buckets, 0, s.bucketsLen - 1).tableDel(bucket)
  ok(idx)

proc grow[K, V](v: var ConcurrentLruCache[K, V], newSize: uint32) =
  let oldSize = v.nodesLen.uint32

  if oldSize >= newSize or newSize <= 1:
    return

  if newSize.int > v.nodesAllocatedLen:
    let nextPower = nextPowerOfTwo(newSize.int)
    v.nodes =
      cast[ptr UncheckedArray[LruNode[K, V]]](resizeShared(v.nodes[0].addr, nextPower))
    v.nodesLen = newSize.int
    v.nodesAllocatedLen = nextPower
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

func resetPayload(n: var LruNode) =
  # Resetting the payload is not needed for the cache itself (it will happily
  # overwrite existing values when the time comes) but for good memory usage
  # hygiene, it's prudent to reset payloads eagerly when they are not trivial
  when not supportsCopyMem(n.K):
    reset(n.key)
  when not supportsCopyMem(n.V):
    reset(n.value)

func init*[K, V](T: type ConcurrentLruCache[K, V], capacity: int): T =
  ## Create a cache with the given initial capacity
  result.capacity = capacity
  result.lock.init()

iterator mruIndices(s: ConcurrentLruCache): uint32 =
  if s.nodesLen > 0:
    var pos = s.nodes[0].next
    for i in 0 ..< s.used:
      yield pos
      pos = s.nodes[pos].next

iterator keys*(s: var ConcurrentLruCache): lent ConcurrentLruCache.K =
  ## Keys in MRU order - starting from the front with the item that was most
  ## recently added or accessed.
  s.lock.lockRead()

  for index in s.mruIndices:
    yield s.nodes[index].key
  
  s.lock.unlockRead()

iterator values*(s: var ConcurrentLruCache, mru: static bool = false): lent ConcurrentLruCache.V =
  ## Values in MRU order - starting from the front with the item that was most
  ## recently added or accessed.
  s.lock.lockRead()

  for index in s.mruIndices:
    yield s.nodes[index].value
  
  s.lock.unlockRead()

iterator mvalues*(s: var ConcurrentLruCache, mru: static bool = false): var ConcurrentLruCache.V =
  ## Values in MRU order - starting from the front with the item that was most
  ## recently added or accessed.
  s.lock.lockWrite()

  for index in s.mruIndices:
    yield s.nodes[index].value
  
  s.lock.unlockWrite()

iterator pairs*(
    s: var ConcurrentLruCache, mru: static bool = false
): (lent ConcurrentLruCache.K, lent ConcurrentLruCache.V) =
  ## Key/value pairs in MRU order - starting from the front with the item that
  ## was most recently added or accessed.
  s.lock.lockRead()

  for index in s.mruIndices:
    yield (s.nodes[index].key, s.nodes[index].value)
  
  s.lock.unlockRead()

iterator mpairs*(
    s: var ConcurrentLruCache, mru: static bool = false
): (lent ConcurrentLruCache.K, var ConcurrentLruCache.V) =
  ## Key/value pairs in MRU order - starting from the front with the item that
  ## was most recently added or accessed.
  s.lock.lockWrite()

  for index in s.mruIndices:
    yield (s.nodes[index].key, s.nodes[index].value)
  
  s.lock.unlockWrite()

func len*(s: var ConcurrentLruCache): int =
  s.lock.lockRead()
  result = int(s.used)
  s.lock.unlockRead()

func capacity*(s: var ConcurrentLruCache): int =
  s.lock.lockRead()
  result = s.capacity
  s.lock.unlockRead()

# TODO: use atomics for used and capacity

func `capacity=`*(s: var ConcurrentLruCache, c: int) =
  ## Update the capacity (but don't reallocate the currenty cache). If the
  ## capacity is smaller than the currently allocated size, it will be ignored.
  s.lock.lockWrite()
  s.capacity = c
  s.lock.unlockWrite()

func contains*(s: var ConcurrentLruCache, key: auto): bool =
  s.lock.lockRead()
  ## Return true iff key can be found in cache - does not update item position
  result = s.used > 0 and s.tableBucket(key).isSome()
  s.lock.unlockRead()

func del*(s: var ConcurrentLruCache, key: auto) =
  ## Remove item from cache, if present - does nothing if it was missing
  s.lock.lockWrite()

  if s.used == 0:
    s.lock.unlockWrite()
    return

  let index = s.tableDel(key).valueOr:
    s.lock.unlockWrite()
    return

  resetPayload(s.nodes[index])

  s.moveToBack(index)
  s.used -= 1

  s.lock.unlockWrite()

func pop*[K, V](s: var ConcurrentLruCache[K, V], key: auto): Opt[V] =
  ## Retrieve item and remove it from LRU cache
  s.lock.lockWrite() 
  
  if s.used == 0:
    s.lock.unlockWrite()
    return Opt.none(V)

  let index = s.tableDel(key).valueOr:
    s.lock.unlockWrite()
    return Opt.none(V)

  result = Opt.some(move(s.nodes[index].value))
  resetPayload(s.nodes[index])

  s.moveToBack(index)
  s.used -= 1

  s.lock.unlockWrite()

# TODO: implement pop without Opt and using move

func get*[K, V](s: var ConcurrentLruCache[K, V], key: auto): Opt[V] =
  ## Retrieve item and move it to the front of the LRU cache
  withWriteLock(s.lock):
    let index = ?s.tableGet(key)
    s.moveToFront(index)
    result = Opt.some(s.nodes[index].value)

func peek*[K, V](s: var ConcurrentLruCache[K, V], key: auto): Opt[V] =
  ## Retrieve item without moving it to the front
  withReadLock(s.lock):
    let index = ?s.tableGet(key)
    result = Opt.some(s.nodes[index].value)

func update*(s: var ConcurrentLruCache, key: auto, value: auto): bool =
  ## Update and move an existing item to the front of the LRU cache - returns
  ## true if the item was updated, false if it was not in the cache
  s.lock.lockWrite()

  let index = s.tableGet(key).valueOr:
    s.lock.unlockWrite()
    return false

  s.nodes[index].value = value
  s.moveToFront(index)
  result = true

  s.lock.unlockWrite()

func refresh*(s: var ConcurrentLruCache, key: auto, value: auto): bool =
  ## Update existing item without moving it to the front of the LRU cache -
  ## returns true if the item was refreshed, false if it was not in the cache
  s.lock.lockWrite()

  let index = s.tableGet(key).valueOr:
    s.lock.unlockWrite()
    return false

  s.nodes[index].value = value
  result = true

  s.lock.unlockWrite()

iterator putWithEvicted*[K, V](
    s: var ConcurrentLruCache, key: K, value: V
): tuple[evicted: bool, key: ConcurrentLruCache.K, value: ConcurrentLruCache.V] =
  ## Insert a new item in the cache, replacing the least recently used one and
  ## yielding the updated or evicted item(s), if any, with their pre-put value.
  ##
  ## Note: Although the API supports evicting more than one item, currently this
  ## cannot cannot happen - future versions may include options for evaluating
  ## the cost of each item at which point several "cheap" items may get evicted
  ## when an expensive item is added.
  #s.lock.lockWrite()

  if s.used + 1 >= s.nodesLen:
    s.grow(uint32(min(s.capacity, targetLen(s.used)) + 1))

  if s.nodesLen > 0: # if capacity was 0, there will be no growth
    let
      subhash = subhash(key)
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
  
  #s.lock.unlockWrite()

func put*(s: var ConcurrentLruCache, key: auto, value: auto) =
  s.lock.lockWrite()

  ## Insert or update an item in the cache, replacing the least recently used
  ## one if inserting the item would exceed capacity.
  {.cast(noSideEffect).}:
    for _ in s.putWithEvicted(key, value):
      discard

  s.lock.unlockWrite()


# TODO: free memory on shutdown