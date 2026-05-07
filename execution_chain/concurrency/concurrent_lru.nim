# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import std/[locks, hashes], results, ./lru

const SHARD_COUNT = 1 shl 6 # 64

type
  Shard[K, V] = object
    lock: Lock
    cache: LruCache[K, V]

  ConcurrentLru*[K, V] = object
    shards: array[SHARD_COUNT, Shard[K, V]]
    mask: uint64 

func isPowerOfTwo(n: static int): bool =
  n > 0 and (n and (n - 1)) == 0

proc init*[K, V](lru: var ConcurrentLru[K, V], totalCapacity: int) =
  const shardCount = SHARD_COUNT
  static:
    doAssert shardCount > 1
    doAssert isPowerOfTwo(shardCount)
  
  let perShard = max(1, totalCapacity div shardCount)

  lru.mask = uint64(shardCount - 1)

  for i in 0 ..< shardCount:
    lru.shards[i].lock.initLock()
    lru.shards[i].cache = LruCache[K, V].init(perShard)

proc dispose*[K, V](lru: var ConcurrentLru[K, V]) =
  for i in 0 ..< lru.shards.len():
    lru.shards[i].lock.deinitLock()
    lru.shards[i].cache.dispose()

template withShard[K, V](lru: ConcurrentLru[K, V], key: K, body: untyped): auto =
  let s {.inject.} = addr lru.shards[int(uint64(hash(key)) and lru.mask)]
  acquire(s.lock)
  try:
    body
  finally:
    release(s.lock)

proc peek*[K, V](lru: var ConcurrentLru[K, V], key: K): Opt[V] =
  let s = addr lru.shards[int(uint64(hash(key)) and lru.mask)]
  s.cache.peek(key)

proc get*[K, V](lru: var ConcurrentLru[K, V], key: K): Opt[V] =
  withShard(lru, key):
    s.cache.get(key)

proc put*[K, V](lru: var ConcurrentLru[K, V], key: K, val: V) =
  withShard(lru, key):
    s.cache.put(key, val)

proc del*[K, V](lru: var ConcurrentLru[K, V], key: K) =
  withShard(lru, key):
    s.cache.del(key)

when isMainModule:
  var test: ConcurrentLru[int, int]
  test.init(1000)

  test.put(1, 1)

  test.put(2, 2)

  test.put(3, 3)
  test.del(3)
  echo test.get(1)
  echo test.peek(2)
  test.dispose()

