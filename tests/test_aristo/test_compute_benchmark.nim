# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/times,
  unittest2,
  ../../execution_chain/db/aristo/[
    aristo_compute,
    aristo_merge,
    aristo_desc,
    aristo_init/memory_only,
    aristo_tx_frame,
  ]

suite "Aristo compute benchmark":
  const 
    NUM_THREADS = 16
    NUM_FRAMES = 10
    NUM_ACCOUNTS_PER_FRAME = 400000

  setup:
    let db = AristoDbRef.init()
    var txFrame = db.txRef
    db.taskpool = Taskpool.new(numThreads = NUM_THREADS)

    for i in 0 ..< NUM_ACCOUNTS_PER_FRAME:
      check:
        txFrame.mergeAccount(
          cast[Hash32](i), 
          AristoAccount(balance: i.u256(), codeHash: EMPTY_CODE_HASH)) == Result[bool, AristoError].ok(true)
    txFrame.checkpoint(1, skipSnapshot = true)

    let batch = db.putBegFn()[]
    db.persist(batch, txFrame)
    check db.putEndFn(batch).isOk()
    
    txFrame = db.baseTxFrame()
    
    for n in 1 .. NUM_FRAMES:
      txFrame = db.txFrameBegin(txFrame)

      let 
        startIdx = NUM_ACCOUNTS_PER_FRAME * n
        endIdx = startIdx + NUM_ACCOUNTS_PER_FRAME

      for i in startIdx ..< endIdx:
        check:
          txFrame.mergeAccount(
            cast[Hash32](i * i), 
            AristoAccount(balance: i.u256(), codeHash: EMPTY_CODE_HASH)) == Result[bool, AristoError].ok(true)
      
      txFrame.checkpoint(1, skipSnapshot = false)

  test "Serial benchmark - skipLayers = false":
    db.parallelStateRootComputation = false
    debugEcho "\nSerial benchmark (skipLayers = false) running..."

    let before = cpuTime()
    check txFrame.computeStateRoot(skipLayers = false).isOk()
    let elapsed = cpuTime() - before
    
    debugEcho "Serial benchmark (skipLayers = false) cpu time: ", elapsed

  test "Parallel benchmark - skipLayers = false":
    db.parallelStateRootComputation = true
    debugEcho "\nParallel benchmark (skipLayers = false) running..."

    let before = cpuTime()
    check txFrame.computeStateRoot(skipLayers = false).isOk()
    let elapsed = cpuTime() - before
    
    debugEcho "Parallel benchmark (skipLayers = false) cpu time: ", elapsed

