# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import std/locks, results

type ConcurrentQueue*[N: static int, T] = object
  lock: Lock
  data: array[N, T]
  headIdx: int
  tailIdx: int
  count: int

template capacity*(q: ConcurrentQueue): int =
  q.data.len() - 1

template toDataIdx(q: ConcurrentQueue, queueIdx: int): int =
  queueIdx mod q.capacity()

template tailDataIdx(q: ConcurrentQueue): int = 
  q.toDataIdx(q.tailIdx)

template headDataIdx(q: ConcurrentQueue): int = 
  q.toDataIdx(q.headIdx)

func isPowerOfTwo(n: static int): bool =
  n > 0 and (n and (n - 1)) == 0

proc init*(q: var ConcurrentQueue) =
  static: 
    doAssert isPowerOfTwo(q.data.len())
  q.lock = Lock()
  initLock(q.lock)

template isEmpty(q: ConcurrentQueue): bool =
  q.headIdx == q.tailIdx

template isFull(q: ConcurrentQueue): bool =
  (q.headIdx + 1) mod q.data.len() == q.tailIdx

proc tryPush*[N, T](q: var ConcurrentQueue[N, T], value: sink T): bool =
  withLock(q.lock):
    if not q.isFull():
      q.data[q.headDataIdx()] = value
      inc q.headIdx
      return true
    else:
      return false
  
proc tryPop*[N, T](q: var ConcurrentQueue[N, T]): Opt[T] =
  withLock(q.lock):
    if not q.isEmpty():
      let value = move(q.data[q.tailDataIdx()])
      inc q.tailIdx
      return Opt.some(value)
    else:
      return Opt.none(T)
      
proc push*[N, T](q: var ConcurrentQueue[N, T], value: T) =
  var pushed = q.tryPush(value)
  while not pushed:
    cpuRelax()
    pushed = q.tryPush(value)

proc pop*[N, T](q: var ConcurrentQueue[N, T]): Opt[T] =
  var popped = q.tryPop()
  while popped.isNone():
    cpuRelax()
    popped = q.tryPop()
  popped

when isMainModule:

  var queue: ConcurrentQueue[4, int]
  queue.init()

  doAssert queue.capacity() == 3
  doAssert queue.isFull() == false
  doAssert queue.isEmpty() == true

  doAssert queue.tryPush(100) == true
  doAssert queue.tryPush(200) == true
  doAssert queue.tryPush(300) == true
  doAssert queue.tryPush(400) == false

  doAssert queue.isFull() == true
  doAssert queue.isEmpty() == false

  doAssert queue.tryPop() == Opt.some(100)
  doAssert queue.tryPop() == Opt.some(200)
  doAssert queue.tryPop() == Opt.some(300)
  doAssert queue.tryPop() == Opt.none(int)

  doAssert queue.isFull() == false
  doAssert queue.isEmpty() == true

  queue.push(100)
  queue.push(200)
  queue.push(300)
  doAssert queue.tryPush(400) == false

  doAssert queue.isFull() == true
  doAssert queue.isEmpty() == false

  doAssert queue.pop() == Opt.some(100)
  doAssert queue.pop() == Opt.some(200)
  doAssert queue.pop() == Opt.some(300)
  doAssert queue.tryPop() == Opt.none(int)

  doAssert queue.isFull() == false
  doAssert queue.isEmpty() == true