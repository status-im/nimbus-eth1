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

export results

const NUM_SHARDS* = 1 shl 6 # 64 shards, must be a power of two

type
  Shard[K, V] = object
    lock: Lock
    cache: LruCache[K, V]

  ConcurrentLruCache*[K, V] = object
    shards: array[NUM_SHARDS, Shard[K, V]]
    mask: uint64 

func isPowerOfTwo(n: static int): bool =
  n > 0 and (n and (n - 1)) == 0

proc init*[K, V](lru: var ConcurrentLruCache[K, V], totalCapacity: int) =
  const shardCount = NUM_SHARDS
  static:
    doAssert shardCount > 1
    doAssert isPowerOfTwo(shardCount)
  
  let perShard = max(1, totalCapacity div shardCount)

  lru.mask = uint64(shardCount - 1)

  for i in 0 ..< shardCount:
    lru.shards[i].lock.initLock()
    lru.shards[i].cache = LruCache[K, V].init(perShard)

proc dispose*[K, V](lru: var ConcurrentLruCache[K, V]) =
  for i in 0 ..< lru.shards.len():
    lru.shards[i].lock.deinitLock()
    lru.shards[i].cache.dispose()

template withShard[K, V](lru: ConcurrentLruCache[K, V], key: K, body: untyped): auto =
  let s {.inject.} = addr lru.shards[int(uint64(hash(key)) and lru.mask)]
  acquire(s.lock)
  try:
    body
  finally:
    release(s.lock)

template numShards*[K, V](lru: ConcurrentLruCache[K, V]): int =
  NUM_SHARDS

template shardCapacity*[K, V](lru: var ConcurrentLruCache[K, V]): int =
  lru.shards[0].cache.capacity
  
func shardLen*[K, V](lru: var ConcurrentLruCache[K, V], key: K): int =
  withShard(lru, key):
    s.cache.len(key)

func capacity*[K, V](lru: var ConcurrentLruCache[K, V]): int =
  lru.shardCapacity() * lru.numShards()
  
func len*[K, V](lru: var ConcurrentLruCache[K, V]): int =
  var len = 0
  for shard in lru.shards.mitems():
    withLock(shard.lock):
      len += shard.cache.len
  len

func contains*[K, V](lru: var ConcurrentLruCache[K, V], key: K): bool =
  withShard(lru, key):
    s.cache.contains(key)

func peek*[K, V](lru: var ConcurrentLruCache[K, V], key: K): Opt[V] =
  withShard(lru, key):
    s.cache.peek(key)

proc get*[K, V](lru: var ConcurrentLruCache[K, V], key: K): Opt[V] =
  withShard(lru, key):
    s.cache.get(key)

proc put*[K, V](lru: var ConcurrentLruCache[K, V], key: K, val: V) =
  withShard(lru, key):
    s.cache.put(key, val)

proc update*[K, V](lru: var ConcurrentLruCache[K, V], key: K, val: V): bool =
  withShard(lru, key):
    s.cache.update(key, val)

proc refresh*[K, V](lru: var ConcurrentLruCache[K, V], key: K, val: V): bool =
  withShard(lru, key):
    s.cache.refresh(key, val)

proc del*[K, V](lru: var ConcurrentLruCache[K, V], key: K) =
  withShard(lru, key):
    s.cache.del(key)

