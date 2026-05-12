# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import std/[locks, atomics]

type
  Semaphore* = object
    count: Atomic[int]
    waiters: Atomic[int]
    lock: Lock
    cond: Cond

proc init*(s: var Semaphore, count: int = 0) =
  initLock(s.lock)
  initCond(s.cond)
  s.count.store(count)
  s.waiters.store(0)

proc dispose*(s: var Semaphore) =
  # Precondition: No other threads should be using the semaphore when dispose is called.
  deinitCond(s.cond)
  deinitLock(s.lock)
  s.count.store(0)
  s.waiters.store(0)

proc `=copy`*(
    dest: var Semaphore, src: Semaphore
) {.error: "Copying Semaphore is forbidden".} =
  discard

proc tryWait*(s: var Semaphore): bool =
  var c = s.count.load()
  while c > 0:
    if s.count.compareExchangeWeak(c, c - 1):
      return true
  false

proc wait*(s: var Semaphore) =
  for _ in 0 ..< 64:
    if tryWait(s): 
      return
    cpuRelax()

  withLock(s.lock):
    s.waiters.atomicInc()
    while not tryWait(s):
      s.cond.wait(s.lock)
    s.waiters.atomicDec()

proc signal*(s: var Semaphore) =
  s.count.atomicInc()
  if s.waiters.load() > 0:
    withLock(s.lock):
      s.cond.signal()