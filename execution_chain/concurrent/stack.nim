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

proc init*(stack: var ConcurrentStack) =  
  stack.lock = Lock()
  initLock(stack.lock)

proc capacity*(stack: ConcurrentStack): int =
  stack.data.len()

proc isEmpty(stack: ConcurrentStack): bool =
  stack.nextIndex == 0

proc isFull(stack: ConcurrentStack): bool =
  stack.nextIndex == stack.data.len() 

proc tryPush*[N, T](stack: var ConcurrentStack[N, T], value: T): bool =
  withLock(stack.lock):
    if not stack.isFull():
      stack.data[stack.nextIndex] = value
      inc stack.nextIndex
      return true
    else:
      return false
  
proc tryPop*[N, T](stack: var ConcurrentStack[N, T]): Opt[T] =
  withLock(stack.lock):
    if not stack.isEmpty():
      let value = stack.data[stack.nextIndex - 1]
      dec stack.nextIndex
      return Opt.some(value)
    else:
      return Opt.none(T)
      
proc push*[N, T](stack: var ConcurrentStack[N, T], value: T) =
  var pushed = stack.tryPush(value)
  while not pushed:
    cpuRelax()
    pushed = stack.tryPush(value)

proc pop*[N, T](stack: var ConcurrentStack[N, T]): Opt[T] =
  var popped = stack.tryPop()
  while popped.isNone():
    cpuRelax()
    popped = stack.tryPop()
  popped

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

  doAssert stack.pop() == Opt.some(100)
  
  doAssert stack.capacity() == 10
  doAssert stack.isFull() == false
  doAssert stack.isEmpty() == true