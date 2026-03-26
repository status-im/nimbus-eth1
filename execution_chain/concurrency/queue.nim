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

import std/[atomics, locks, math], results

type ConcurrentQueue*[E: static int, T] = object
  data: array[1 shl E, T]
  exp: int
  indexes: Atomic[uint32]
  lockFull: Lock
  condFull: Cond
  lockEmpty: Lock
  condEmpty: Cond
  
template capacity*(q: ConcurrentQueue): int =
  q.data.len() - 1

func isPowerOfTwo(n: static int): bool =
  n > 0 and (n and (n - 1)) == 0

func init*(q: var ConcurrentQueue) =
  static:
    doAssert q.data.len() > 1
    doAssert isPowerOfTwo(q.data.len())
  q.exp = log2(q.data.len().float).int
  q.indexes.store(0.uint32)
  q.lockFull.initLock()
  q.condFull.initCond()
  q.lockEmpty.initLock()
  q.condEmpty.initCond()

func pushBegin(q: var ConcurrentQueue): int =
  let
    r = q.indexes.load().int
    mask = (1 shl q.exp) - 1
    head = r and mask
    tail = r shr 16 and mask
    next = (head + 1) and mask

  if (r and 0x8000) > 0: # avoid overflow on commit
    discard q.indexes.fetchAnd(not 0x8000.uint32)

  if next == tail: -1 else: head

template pushCommit(q: var ConcurrentQueue) =
  q.indexes.atomicInc()

func popBegin(q: var ConcurrentQueue): int =
  let
    r = q.indexes.load().int
    mask = (1 shl q.exp) - 1
    head = r and mask
    tail = r shr 16 and mask

  if head == tail: -1 else: tail

template popCommit(q: var ConcurrentQueue) =
  q.indexes += 0x10000

template isFull*[E, T](q: var ConcurrentQueue[E, T]): bool =
  q.pushBegin() < 0

template isEmpty*[E, T](q: var ConcurrentQueue[E, T]): bool =
  q.popBegin() < 0

func tryPush*[E, T](q: var ConcurrentQueue[E, T], value: sink T): bool =
  let headIdx = q.pushBegin()
  if headIdx < 0:
    false
  else:
    q.data[headIdx] = value
    q.pushCommit()
    q.condEmpty.signal()
    true

func tryPop*[E, T](q: var ConcurrentQueue[E, T], value: var T): bool =
  let tailIdx = q.popBegin()
  if tailIdx < 0:
    false
  else:
    value = move(q.data[tailIdx])
    q.popCommit()
    q.condFull.signal()
    true

template tryPop*[E, T](q: var ConcurrentQueue[E, T]): Opt[T] =
  var value: T
  if q.tryPop(value):
    Opt.some(value)
  else:
    Opt.none(T)

func push*[E, T](q: var ConcurrentQueue[E, T], value: sink T) =
  var headIdx = q.pushBegin()

  withLock(q.lockFull):
    while headIdx < 0:
      q.condFull.wait(q.lockFull)
      headIdx = q.pushBegin()

  q.data[headIdx] = value
  q.pushCommit()
  q.condEmpty.signal()

func pop*[E, T](q: var ConcurrentQueue[E, T], value: var T) =
  var tailIdx = q.popBegin()

  withLock(q.lockEmpty):
    while tailIdx < 0:
      q.condEmpty.wait(q.lockEmpty)
      tailIdx = q.popBegin()

  value = move(q.data[tailIdx])
  q.popCommit()
  q.condFull.signal()

template pop*[E, T](q: var ConcurrentQueue[E, T]): T =
  var value: T
  q.pop(value)
  value

func dispose*(q: var ConcurrentQueue) =
  q.lockFull.deinitLock()
  q.condFull.deinitCond()
  q.lockEmpty.deinitLock()
  q.condEmpty.deinitCond()

