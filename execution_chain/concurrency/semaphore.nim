# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import std/locks

type
  Semaphore* = object
    lock: Lock
    cond: Cond
    count: int

proc init*(s: var Semaphore, count: int = 0) =
  initLock(s.lock)
  initCond(s.cond)
  s.count = count

func init*(T: type Semaphore, count: int = 0): T =
  var s = Semaphore()
  s.init(count)
  s

proc dispose*(s: var Semaphore) =
  s.cond.broadcast() # unblock waiters
  deinitLock(s.lock)
  deinitCond(s.cond)
  s.count = 0

proc tryWait*(s: var Semaphore): bool =
  withLock(s.lock):
    if s.count > 0:
      dec s.count
      return true
    else:
      return false

proc wait*(s: var Semaphore) =
  withLock(s.lock):
    while s.count == 0:
      s.cond.wait(s.lock)
    dec s.count

proc signal*(s: var Semaphore) =
  withLock(s.lock):
    inc s.count
    s.cond.signal()
