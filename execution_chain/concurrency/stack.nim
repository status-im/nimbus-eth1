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

type ConcurrentStack*[N: static int, T] = object
  lock: Lock
  data: array[N, T]
  nextIndex: int

proc init*(s: var ConcurrentStack) =  
  s.lock = Lock()
  initLock(s.lock)

template capacity*(s: ConcurrentStack): int =
  s.data.len()

template isEmptyImpl(s: ConcurrentStack): bool =
  s.nextIndex == 0

template isEmpty*(s: ConcurrentStack): bool =
  s.lock.acquire()
  let empty = s.isEmptyImpl()
  s.lock.release()
  empty

template isFull(s: ConcurrentStack): bool =
  s.nextIndex == s.data.len() 

proc tryPush*[N, T](s: var ConcurrentStack[N, T], value: T): bool =
  withLock(s.lock):
    if not s.isFull():
      s.data[s.nextIndex] = value
      inc s.nextIndex
      return true
    else:
      return false
  
proc tryPop*[N, T](s: var ConcurrentStack[N, T], value: var T): bool =
  withLock(s.lock):
    if not s.isEmptyImpl():
      value = move(s.data[s.nextIndex - 1])
      dec s.nextIndex
      return true
    else:
      return false
      
proc push*[N, T](s: var ConcurrentStack[N, T], value: T) =
  var pushed = s.tryPush(value)
  while not pushed:
    cpuRelax()
    pushed = s.tryPush(value)

proc pop*[N, T](s: var ConcurrentStack[N, T]): T =
  var 
    value: T 
    popped = s.tryPop(value)
  while not popped:
    cpuRelax()
    popped = s.tryPop(value)
  value

when isMainModule:

  var stack: ConcurrentStack[10, int]
  stack.init()

  doAssert stack.capacity() == 10
  doAssert stack.isFull() == false
  doAssert stack.isEmpty() == true

  #doAssert stack.push(100) == true
  stack.push(100)

  doAssert stack.capacity() == 10
  doAssert stack.isFull() == false
  doAssert stack.isEmpty() == false

  doAssert stack.pop() == 100
  
  doAssert stack.capacity() == 10
  doAssert stack.isFull() == false
  doAssert stack.isEmpty() == true