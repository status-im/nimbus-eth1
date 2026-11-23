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
  std/typedthreads,
  taskpools,
  ./semaphore

type
  DetachedTaskpoolObj = object
    pool: Taskpool
    started: Semaphore
    stop: Semaphore
    thread: Thread[(ptr DetachedTaskpoolObj, int)]

  DetachedTaskpool* = ptr DetachedTaskpoolObj

proc ownerThread(args: (ptr DetachedTaskpoolObj, int)) {.thread.} =
  let (p, numWorkers) = args
  try:
    p[].pool = Taskpool.new(numThreads = numWorkers + 1)
  except CatchableError:
    discard
  p[].started.signal()

  if not p[].pool.isNil():
    p[].stop.wait()
    p[].pool.shutdown()

proc dispose(p: DetachedTaskpool) =
  p[].started.dispose()
  p[].stop.dispose()
  deallocShared(p)

proc new*(
    T: type DetachedTaskpool, numWorkers: int
): T {.raises: [CatchableError].} =
  let p = createShared(DetachedTaskpoolObj)
  p[].started.init()
  p[].stop.init()
  try:
    createThread(p[].thread, ownerThread, (p, numWorkers))
  except ResourceExhaustedError as exc:
    p.dispose()
    raise exc

  p[].started.wait()

  if p[].pool.isNil():
    joinThread(p[].thread)
    p.dispose()
    raise newException(CatchableError, "Failed to create the taskpool threads")

  p

func taskpool*(p: DetachedTaskpool): Taskpool =
  p[].pool

func numWorkers*(p: DetachedTaskpool): int =
  p[].pool.numThreads - 1

proc shutdown*(p: var DetachedTaskpool) =
  p[].stop.signal()
  joinThread(p[].thread)
  p.dispose()
  p = nil
