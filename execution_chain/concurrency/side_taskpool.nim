# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  std/[atomics, os, typedthreads],
  taskpools

type
  SideTaskpoolObj = object
    pool: Taskpool
    numWorkers: int
    ready: Atomic[bool]
    failed: Atomic[bool]
    stop: Atomic[bool]
    thread: Thread[ptr SideTaskpoolObj]

  SideTaskpool* = ptr SideTaskpoolObj

proc ownerThread(p: ptr SideTaskpoolObj) {.thread.} =
  var tp: Taskpool
  try:
    tp = Taskpool.new(numThreads = p[].numWorkers + 1)
  except CatchableError:
    p[].failed.store(true, moRelease)
    p[].ready.store(true, moRelease)
    return

  p[].pool = tp
  p[].ready.store(true, moRelease)

  while not p[].stop.load(moAcquire):
    sleep(50)

  tp.shutdown()

proc new*(T: type SideTaskpool, numWorkers: int): T =
  let p = createShared(SideTaskpoolObj)
  p[].numWorkers = numWorkers
  try:
    createThread(p[].thread, ownerThread, p)
  except ResourceExhaustedError:
    deallocShared(p)
    return nil

  while not p[].ready.load(moAcquire):
    sleep(1)

  if p[].failed.load(moAcquire):
    joinThread(p[].thread)
    deallocShared(p)
    return nil

  p

func taskpool*(p: SideTaskpool): Taskpool =
  p[].pool

func numWorkers*(p: SideTaskpool): int =
  p[].numWorkers

proc shutdown*(p: SideTaskpool) =
  if p.isNil():
    return
  p[].stop.store(true, moRelease)
  joinThread(p[].thread)
  deallocShared(p)
