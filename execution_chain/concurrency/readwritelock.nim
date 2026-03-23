# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This implements a writer preferring read-write lock using a lock
## and a condition varable. Multiple readers can hold the lock concurrently
## but only a single write is allowed to hold the lock.

{.push raises: [], gcsafe.}

import std/locks

type ReadWriteLock* = object
  lock: Lock
  cond: Cond
  readerCount: int
  hasWriter: bool

func init*(rwLock: var ReadWriteLock) =
  initLock(rwLock.lock)
  initCond(rwLock.cond)

func init*(T: type ReadWriteLock): T =
  var rwLock = ReadWriteLock()
  rwLock.init()
  rwLock

func lockRead*(rwLock: var ReadWriteLock) =
  withLock(rwLock.lock):
    while rwLock.hasWriter:
      rwLock.cond.wait(rwLock.lock)
    inc rwLock.readerCount

func unlockRead*(rwLock: var ReadWriteLock) =
  withLock(rwLock.lock):
    dec rwLock.readerCount
    if rwLock.readerCount == 0:
      rwLock.cond.broadcast()

func lockWrite*(rwLock: var ReadWriteLock) =
  withLock(rwLock.lock):
    while rwLock.hasWriter:
      rwLock.cond.wait(rwLock.lock)
    rwLock.hasWriter = true
    while rwLock.readerCount > 0:
      rwLock.cond.wait(rwLock.lock)

func unlockWrite*(rwLock: var ReadWriteLock) =
  withLock(rwLock.lock):
    rwLock.hasWriter = false
    rwLock.cond.broadcast()

template withReadLock*(rwLock: var ReadWriteLock, body: untyped) =
  rwLock.lockRead()
  try:
    body
  finally:
    rwLock.unlockRead()

template withWriteLock*(rwLock: var ReadWriteLock, body: untyped) =
  rwLock.lockWrite()
  try:
    body
  finally:
    rwLock.unlockWrite()

when isMainModule:
  var rwLock = ReadWriteLock.init()

  rwLock.lockRead()
  rwLock.unlockRead()
  rwLock.lockWrite()
  rwLock.unlockWrite()

  rwLock.lockRead()
  rwLock.lockRead()
  rwLock.lockRead()
  rwLock.unlockRead()
  rwLock.unlockRead()
  rwLock.unlockRead()
  rwLock.lockWrite()
  rwLock.unlockWrite()
