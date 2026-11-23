# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## A taskpool owned by a dedicated thread. nim-taskpools keeps its worker
## context in a threadvar, so `Taskpool.new` makes the calling thread the root
## of the new pool and a thread can only be the root of one pool. The main
## thread is already the root of the shared taskpool, so this pool is created
## and shut down on its own thread while other threads submit work to it.
##
## TODO: Fix nim-taskpools so that multiple taskpools can be created from the
## same thread, if possible, and then remove this type.

{.push raises: [], gcsafe.}

import
  std/[atomics, os, typedthreads],
  taskpools

type
  DetachedTaskpoolObj = object
    pool: Taskpool
    running: Atomic[bool]
    thread: Thread[(ptr DetachedTaskpoolObj, int)]

  DetachedTaskpool* = ptr DetachedTaskpoolObj

proc ownerThread(args: (ptr DetachedTaskpoolObj, int)) {.thread.} =
  let (p, numWorkers) = args
  try:
    p[].pool = Taskpool.new(numThreads = numWorkers + 1)
  except CatchableError as exc:
    raiseAssert exc.msg
  p[].running.store(true, moRelease)

  while p[].running.load(moAcquire):
    sleep(50)

  p[].pool.shutdown()

proc new*(T: type DetachedTaskpool, numWorkers: int): T =
  let p = createShared(DetachedTaskpoolObj)
  try:
    createThread(p[].thread, ownerThread, (p, numWorkers))
  except ResourceExhaustedError as exc:
    raiseAssert exc.msg

  while not p[].running.load(moAcquire):
    sleep(1)

  p

func taskpool*(p: DetachedTaskpool): Taskpool =
  p[].pool

func numWorkers*(p: DetachedTaskpool): int =
  p[].pool.numThreads - 1

proc shutdown*(p: DetachedTaskpool) =
  p[].running.store(false, moRelease)
  joinThread(p[].thread)
  deallocShared(p)
