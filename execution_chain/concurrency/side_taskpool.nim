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
    running: Atomic[bool]
    thread: Thread[(ptr SideTaskpoolObj, int)]

  SideTaskpool* = ptr SideTaskpoolObj

proc ownerThread(args: (ptr SideTaskpoolObj, int)) {.thread.} =
  let (p, numWorkers) = args
  try:
    p[].pool = Taskpool.new(numThreads = numWorkers + 1)
  except CatchableError as exc:
    raiseAssert exc.msg
  p[].running.store(true, moRelease)

  while p[].running.load(moAcquire):
    sleep(50)

  p[].pool.shutdown()

proc new*(T: type SideTaskpool, numWorkers: int): T =
  let p = createShared(SideTaskpoolObj)
  try:
    createThread(p[].thread, ownerThread, (p, numWorkers))
  except ResourceExhaustedError as exc:
    raiseAssert exc.msg

  while not p[].running.load(moAcquire):
    sleep(1)

  p

func taskpool*(p: SideTaskpool): Taskpool =
  p[].pool

func numWorkers*(p: SideTaskpool): int =
  p[].pool.numThreads - 1

proc shutdown*(p: SideTaskpool) =
  p[].running.store(false, moRelease)
  joinThread(p[].thread)
  deallocShared(p)
