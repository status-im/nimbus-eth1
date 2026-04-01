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

import results, taskpools, unittest2, ../../execution_chain/concurrency/queue


suite "ConcurrentQueue Tests":

  test "init, capacity, dispose":
    block:
      var queue: ConcurrentQueue[2, int]
      queue.init()
      check queue.capacity() == 3
      queue.dispose()

    block:
      var queue: ConcurrentQueue[3, int]
      queue.init()
      check queue.capacity() == 7
      queue.dispose()

    block:
      var queue: ConcurrentQueue[4, int]
      queue.init()
      check queue.capacity() == 15
      queue.dispose()

  test "isFull, isEmpty":
    var queue: ConcurrentQueue[2, int]
    queue.init()

    check:
      queue.isFull() == false
      queue.isEmpty() == true
    
    queue.push(100)
  
    check:
      queue.isFull() == false
      queue.isEmpty() == false

    queue.push(200)

    check:
      queue.isFull() == false
      queue.isEmpty() == false
    
    queue.push(300)

    check:
      queue.isFull() == true
      queue.isEmpty() == false

  test "tryPush, tryPop":
    var queue: ConcurrentQueue[2, int]
    queue.init()

    check:
      queue.tryPush(100) == true
      queue.tryPush(200) == true
      queue.tryPush(300) == true
      queue.tryPush(400) == false

      queue.isFull() == true
      queue.tryPop() == Opt.some(100)
      queue.isFull() == false
      queue.tryPop() == Opt.some(200)
    
    var value: int
    check: 
      queue.isEmpty() == false
      queue.tryPop(value) == true
      queue.isEmpty() == true
      queue.tryPop(value) == false
      value == 300

  test "push, pop":
    var queue: ConcurrentQueue[2, int]
    queue.init()

    queue.push(100)
    queue.push(200)
    queue.push(300)

    check: 
      queue.isFull() == true
      queue.pop() == 100
      queue.pop() == 200

    var value: int
    queue.pop(value)

    check:
      value == 300
      queue.isEmpty() == true

  test "Misc operations":
    var queue: ConcurrentQueue[2, int]
    queue.init()

    check:
      queue.capacity() == 3
      queue.tryPush(100) == true
      queue.tryPush(200) == true
      queue.tryPush(300) == true
      queue.tryPush(400) == false
      queue.tryPop() == Opt.some(100)
      queue.tryPop() == Opt.some(200)
      queue.tryPop() == Opt.some(300)
      queue.tryPop() == Opt.none(int)

    queue.push(500)
    queue.push(700)
    queue.push(600)

    check:
      queue.tryPush(400) == false
      queue.pop() == 500
      queue.pop() == 700
      queue.pop() == 600
      queue.tryPop() == Opt.none(int)
    
    queue.push(400)
    check queue.pop() == 400
  
  test "Single producer task, single consumer task, multiple threads":
    let taskpool = Taskpool.new(numThreads = 2)

    var queue: ConcurrentQueue[2, int]
    queue.init()

    const NUM_ITEMS = 100

    proc producer(q: ptr ConcurrentQueue[2, int], useTry: bool): int =
      var count = 0
      for i in 0 ..< NUM_ITEMS:
        if useTry:
          while not q[].tryPush(i):
            cpuRelax()
        else:
          q[].push(i)
        inc count
      count

    proc consumer(q: ptr ConcurrentQueue[2, int], useTry: bool): int =
      var count = 0
      for i in 0 ..< NUM_ITEMS:
        if useTry:
          while q[].tryPop().isNone():
            cpuRelax()
        else:
          discard q[].pop()
        inc count
      count

    block:
      let 
        f1 = taskpool.spawn producer(queue.addr, useTry = false)
        f2 = taskpool.spawn consumer(queue.addr, useTry = false)

      check: 
        sync(f1) == NUM_ITEMS
        sync(f2) == NUM_ITEMS

    block:
      let 
        f1 = taskpool.spawn producer(queue.addr, useTry = false)
        f2 = taskpool.spawn consumer(queue.addr, useTry = true)

      check: 
        sync(f1) == NUM_ITEMS
        sync(f2) == NUM_ITEMS

    block:
      let 
        f1 = taskpool.spawn producer(queue.addr, useTry = true)
        f2 = taskpool.spawn consumer(queue.addr, useTry = false)

      check: 
        sync(f1) == NUM_ITEMS
        sync(f2) == NUM_ITEMS

    block:
      let 
        f1 = taskpool.spawn producer(queue.addr, useTry = true)
        f2 = taskpool.spawn consumer(queue.addr, useTry = true)

      check: 
        sync(f1) == NUM_ITEMS
        sync(f2) == NUM_ITEMS