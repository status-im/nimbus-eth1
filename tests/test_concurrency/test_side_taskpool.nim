# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/atomics,
  unittest2,
  taskpools,
  ../../execution_chain/concurrency/side_taskpool

proc addTask(counter: ptr Atomic[int], v: int): int {.nimcall.} =
  discard counter[].fetchAdd(v, moRelaxed)
  v * 2

suite "SideTaskpool":
  test "Spawn from the root thread of another taskpool":
    var shared = Taskpool.new(numThreads = 2)
    let side = SideTaskpool.new(4)
    check side.numWorkers == 4

    var counter: Atomic[int]
    var futs = newSeq[Flowvar[int]](100)
    for i in 0 ..< futs.len:
      futs[i] = side.taskpool.spawn addTask(counter.addr, i)

    var total = 0
    for f in futs.mitems():
      total += sync(f)

    check:
      total == 2 * (99 * 100 div 2)
      counter.load() == 99 * 100 div 2

    side.shutdown()
    shared.shutdown()
