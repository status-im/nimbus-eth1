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

proc `=copy`(dst: var Semaphore, src: Semaphore) {.error.}
proc `=dup`(src: Semaphore): Semaphore {.error.}

proc init*(s: var Semaphore, count: int = 0) =
  initLock(s.lock)
  initCond(s.cond)
  s.count = count

proc dispose*(s: var Semaphore) =
  # Precondition: No other thread is using the semaphone when dispose is called.
  deinitCond(s.cond)
  deinitLock(s.lock)
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
