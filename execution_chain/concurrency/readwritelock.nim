# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This implements a writer preferring read-write lock using a lock
## and two condition varables. Multiple readers can hold the lock concurrently
## but only a single write is allowed to hold the lock.

{.push raises: [], gcsafe.}

import std/[atomics, locks], ./semaphore

const MAX_READERS: int32 = 1 shl 30

type
  ReadWriteLock* = object
    lock: Lock                         
    writerWait: Semaphore     
    readerWait: Semaphore   
    numPending: Atomic[int32]     
    readersDeparting: Atomic[int32]

proc init*(l: var ReadWriteLock) =
  initLock(l.lock)
  l.writerWait.init()
  l.readerWait.init()
  l.numPending.store(0)
  l.readersDeparting.store(0)

func init*(T: type ReadWriteLock): T =
  var l = ReadWriteLock()
  l.init()
  l

proc dispose*(l: var ReadWriteLock) =
  deinitLock(l.lock)
  l.writerWait.dispose()
  l.readerWait.dispose()

template atomicAdd(a: var Atomic[int32], delta: int32): int32 =
  a.fetchAdd(delta) + delta

proc lockRead*(l: var ReadWriteLock) =
  if atomicAdd(l.numPending, 1) < 0:
    l.readerWait.wait()

proc unlockRead*(l: var ReadWriteLock) =
  let r = atomicAdd(l.numPending, -1)
  if r < 0:
    assert r + 1 != 0 and r + 1 != -MAX_READERS
    if atomicAdd(l.readersDeparting, -1) == 0:
      l.writerWait.signal()

proc lockWrite*(l: var ReadWriteLock) =
  acquire(l.lock)
  let r = atomicAdd(l.numPending, -MAX_READERS) + MAX_READERS
  if r != 0 and atomicAdd(l.readersDeparting, r) != 0:
    l.writerWait.wait()

proc unlockWrite*(l: var ReadWriteLock) =
  let r = atomicAdd(l.numPending, MAX_READERS)
  assert r < MAX_READERS
  for i in 0 ..< int(r):
    l.readerWait.signal()
  release(l.lock)

template withReadLock*(l: var ReadWriteLock, body: untyped) =
  l.lockRead()
  try:
    body
  finally:
    l.unlockRead()

template withWriteLock*(l: var ReadWriteLock, body: untyped) =
  l.lockWrite()
  try:
    body
  finally:
    l.unlockWrite()


