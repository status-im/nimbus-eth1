# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This implements a (mostly) lock free thread safe concurrent queue which is designed
## specifically for the single producer - single consumer scenario.
## The queue is not designed to be thread safe when used by multiple producers 
## and consumer threads.
## Inspired by this blog post: https://nullprogram.com/blog/2022/05/14/
## The size of the queue needs to be a power of 2.
## E is the exponent so when E has a value of 2 the data array will have len 4.
## T is the element type to be stored in the queue.

{.push raises: [], gcsafe.}

import std/[atomics, locks, typetraits], results
 
const CACHE_LINE_SIZE = when defined(macosx) and defined(arm64): 128 else: 64
 
type
  State {.pure.} = enum
    UNINITIALIZED
    INITIALIZED
    DISPOSED

  ConcurrentQueue*[E: static int, T] = object
    head {.align: CACHE_LINE_SIZE.}: Atomic[uint32]
    cachedTail: uint32
    waitingPop: Atomic[bool]

    tail {.align: CACHE_LINE_SIZE.}: Atomic[uint32]
    cachedHead: uint32
    waitingPush: Atomic[bool]

    lock {.align: CACHE_LINE_SIZE.}: Lock
    condFull: Cond
    condEmpty: Cond
    state: State

    data {.align: CACHE_LINE_SIZE.}: array[1 shl E, T]  
 
func init*[E, T](q: var ConcurrentQueue[E, T]) =
  static:
    doAssert supportsCopyMem(T), "T must be a non-GC type"
    doAssert E >= 1, "queue exponent must be >= 1 (capacity >= 1)"
    doAssert E <= 30, "queue exponent too large for uint32 indices"
  doAssert q.state == State.UNINITIALIZED

  q.head.store(0'u32)
  q.tail.store(0'u32)
  q.cachedHead = 0
  q.cachedTail = 0
  q.waitingPush.store(false)
  q.waitingPop.store(false)
  q.lock.initLock()
  q.condFull.initCond()
  q.condEmpty.initCond()
  q.state = State.INITIALIZED
 
func dispose*[E, T](q: var ConcurrentQueue[E, T]) =
  doAssert q.state == State.INITIALIZED

  q.lock.deinitLock()
  q.condFull.deinitCond()
  q.condEmpty.deinitCond()
  q.state = State.DISPOSED

proc `=copy`*[E, T](
    dest: var ConcurrentQueue[E, T], src: ConcurrentQueue[E, T]
) {.error: "Copying ConcurrentQueue is forbidden".} =
  discard

template capacity*(q: ConcurrentQueue): int =
  q.data.len() - 1

template maskOf(E: static int): uint32 = uint32((1 shl E) - 1)
 
template isEmpty*[E, T](q: var ConcurrentQueue[E, T]): bool =
  q.tail.load() == q.head.load()
 
template isFull*[E, T](q: var ConcurrentQueue[E, T]): bool =
  let h = q.head.load()
  ((h + 1) and maskOf(E)) == q.tail.load()
 
func tryPush*[E, T](q: var ConcurrentQueue[E, T], value: sink T): bool =
  const m = maskOf(E)
  let h = q.head.load()    
  let next = (h + 1) and m
 
  if next == q.cachedTail:
    q.cachedTail = q.tail.load()
    if next == q.cachedTail:
      return false                    
 
  q.data[h] = value
  q.head.store(next)        
 
  if q.waitingPop.load():
    withLock(q.lock):
      q.condEmpty.signal()
  true
 
func tryPop*[E, T](q: var ConcurrentQueue[E, T], value: var T): bool =
  const m = maskOf(E)
  let t = q.tail.load()
 
  if t == q.cachedHead:
    q.cachedHead = q.head.load()
    if t == q.cachedHead:
      return false
 
  value = move(q.data[t])
  q.tail.store((t + 1) and m)
 
  if q.waitingPush.load():
    withLock(q.lock):
      q.condFull.signal()
  true
 
template tryPop*[E, T](q: var ConcurrentQueue[E, T]): Opt[T] =
  var value: T
  if q.tryPop(value):
    Opt.some(value)
  else:
    Opt.none(T)
 
func push*[E, T](q: var ConcurrentQueue[E, T], value: sink T) =
  if q.tryPush(value):
    return
 
  const m = maskOf(E)
  withLock(q.lock):
    q.waitingPush.store(true)
    while true:
      let h = q.head.load()
      let next = (h + 1) and m
      q.cachedTail = q.tail.load()
      if next != q.cachedTail:
        q.data[h] = value
        q.head.store(next)
        q.waitingPush.store(false)
        q.condEmpty.signal()
        return
      q.condFull.wait(q.lock)
 
func pop*[E, T](q: var ConcurrentQueue[E, T], value: var T) =
  if q.tryPop(value):
    return
 
  const m = maskOf(E)
  withLock(q.lock):
    q.waitingPop.store(true)
    while true:
      let t = q.tail.load()
      q.cachedHead = q.head.load()
      if t != q.cachedHead:
        value = move(q.data[t])
        q.tail.store((t + 1) and m)
        q.waitingPop.store(false)
        q.condFull.signal()
        return
      q.condEmpty.wait(q.lock)
 
template pop*[E, T](q: var ConcurrentQueue[E, T]): T =
  var value: T
  q.pop(value)
  value