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

template capacity*(q: ConcurrentQueue): int =
  q.data.len() - 1

template toDataIdx(q: ConcurrentQueue, queueIdx: int): int =
  queueIdx mod q.data.len()

template tailDataIdx(q: ConcurrentQueue): int = 
  q.toDataIdx(q.tailIdx)

template headDataIdx(q: ConcurrentQueue): int = 
  q.toDataIdx(q.headIdx)

func isPowerOfTwo(n: static int): bool =
  n > 0 and (n and (n - 1)) == 0

proc init*(q: var ConcurrentQueue) =
  static: 
    doAssert isPowerOfTwo(q.data.len())
  # q.lock = Lock()
  initLock(q.lock)

template isEmptyImpl(q: ConcurrentQueue): bool =
  q.headIdx == q.tailIdx

template isEmpty*(q: ConcurrentQueue): bool =
  q.lock.acquire()
  let empty = q.isEmptyImpl()
  q.lock.release()
  empty

template isFull(q: ConcurrentQueue): bool =
  (q.headIdx + 1) mod q.data.len() == q.tailIdx

proc tryPush*[N, T](q: var ConcurrentQueue[N, T], value: sink T): bool =
  withLock(q.lock):
    if not q.isFull():
      #let currentIdx = q.headDataIdx()
      q.data[q.headIdx] = value
      q.headIdx = q.toDataIdx(q.headIdx + 1)
      return true
    else:
      return false
  
proc tryPop*[N, T](q: var ConcurrentQueue[N, T], value: var T): bool =
  withLock(q.lock):
    if not q.isEmptyImpl():
      #let currentIdx = q.tailDataIdx()
      value = move(q.data[q.tailIdx])
      q.tailIdx = q.toDataIdx(q.tailIdx + 1)
      return true
    else:
      return false
      
proc push*[N, T](q: var ConcurrentQueue[N, T], value: T) =
  var pushed = q.tryPush(value)
  while not pushed:
    cpuRelax()
    pushed = q.tryPush(value)

proc pop*[N, T](q: var ConcurrentQueue[N, T]): T =
  var 
    value: T 
    popped = q.tryPop(value)
  while not popped:
    cpuRelax()
    popped = q.tryPop(value)
  value

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

  var x: int
  doAssert queue.tryPop(x) == true and x == 100
  doAssert queue.pop() == 200
  doAssert queue.pop() == 300
  doAssert queue.tryPop(x) == false

  doAssert queue.isFull() == false
  doAssert queue.isEmpty() == true

  queue.push(100)
  queue.push(200)
  queue.push(300)
  doAssert queue.tryPush(400) == false

  doAssert queue.isFull() == true
  doAssert queue.isEmpty() == false

  doAssert queue.pop() == 100
  doAssert queue.pop() == 200
  doAssert queue.pop() == 300
  doAssert queue.tryPop(x) == false

  doAssert queue.isFull() == false
  doAssert queue.isEmpty() == true