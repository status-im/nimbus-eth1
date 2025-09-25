# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  unittest2,
  stew/endians2,
  results,
  eth/common/hashes,
  ../../execution_chain/db/aristo/[
    aristo_delete,
    aristo_desc,
    aristo_fetch,
    aristo_tx_frame,
    aristo_init/init_common,
    aristo_init/memory_only,
    aristo_layers,
    aristo_merge,
  ]

proc makeAccount(i: uint64): (Hash32, AristoAccount) =
  var path: Hash32
  path.data()[0 .. 7] = i.toBytesBE()
  (path, AristoAccount(balance: i.u256, codeHash: EMPTY_CODE_HASH))

const
  acc1 = makeAccount(1)
  acc2 = makeAccount(2)
  acc3 = makeAccount(3)

suite "Aristo TxFrame":
  setup:
    let db = AristoDbRef.init()

  test "Frames should independently keep data":
    let
      tx0 = db.txFrameBegin(db.baseTxFrame())
      tx1 = db.txFrameBegin(tx0)
      tx2 = db.txFrameBegin(tx1)
      tx2b = db.txFrameBegin(tx1)
      tx2c = db.txFrameBegin(tx1)

    check:
      tx0.mergeAccountRecord(acc1[0], acc1[1]).isOk()
      tx1.mergeAccountRecord(acc2[0], acc2[1]).isOk()
      tx2.deleteAccountRecord(acc2[0]).isOk()
      tx2b.deleteAccountRecord(acc1[0]).isOk()
      tx2c.mergeAccountRecord(acc2[0], acc3[1]).isOk()

    check:
      tx0.fetchAccountRecord(acc1[0]).isOk()
      tx0.fetchAccountRecord(acc2[0]).isErr() # Doesn't exist in tx0
      tx1.fetchAccountRecord(acc1[0]).isOk()
      tx1.fetchAccountRecord(acc1[0]).isOk()
      tx2.fetchAccountRecord(acc1[0]).isOk()
      tx2.fetchAccountRecord(acc2[0]).isErr() # Doesn't exist in tx2
      tx2b.fetchAccountRecord(acc1[0]).isErr() # Doesn't exist in tx2b

      tx0.fetchAccountRecord(acc1[0]) == tx2.fetchAccountRecord(acc1[0])

      tx0.fetchStateRoot() != tx1.fetchStateRoot()
      tx0.fetchStateRoot() == tx2.fetchStateRoot()

    var acc1Hike: Hike
    check:
      tx2c.fetchAccountHike(acc1[0], acc1Hike).isOk()

      # The vid for acc1 gets created in tx1 because it has to move to a new
      # mpt node from the root - tx2c updates only data, so the level at which
      # we find the vtx should be one below tx2c!
      (
        tx2c.level -
        tx2c.layersGetVtx((STATE_ROOT_VID, acc1Hike.legs[^1].wp.vid)).value()[1]
      ) == 1

    tx0.checkpoint(1, skipSnapshot = false)
    tx1.checkpoint(2, skipSnapshot = false)
    tx2.checkpoint(3, skipSnapshot = false)
    tx2b.checkpoint(3, skipSnapshot = false)
    tx2c.checkpoint(3, skipSnapshot = false)

    check:
      # Even after checkpointing, we should maintain the same relative levels
      (
        tx2c.level -
        tx2c.layersGetVtx((STATE_ROOT_VID, acc1Hike.legs[^1].wp.vid)).value()[1]
      ) == 1

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx2)
    check:
      db.putEndFn(batch).isOk()

    db.finish()

    block:
      # using the same backend but new txRef and cache
      db.initInstance().expect("working backend")
      let tx = db.baseTxFrame()
      check:
        tx.fetchAccountRecord(acc1[0]).isOk()
        tx.fetchAccountRecord(acc2[0]).isErr() # Doesn't exist in tx2

  # This test case reproduces a bug which triggers an:
  # `db.txId == 0`  [AssertionDefect]
  # This occurs when the txId inside the database is (incorrectly) expected to always
  # be equal to zero when starting a batch.
  # See the related issue here: https://github.com/status-im/nimbus-eth1/issues/3659
  # and the related file here: https://github.com/status-im/nimbus-eth1/blob/master/execution_chain/db/aristo/aristo_init/init_common.nim
  # When passing in a stateroot to the persist call it is possible
  # for a nested batch to be created withing the call to compute the stateroot
  # and at this point the db.txId will be non zero.
  test "After snapshots can persist checking state root":
    let tx1 = db.txFrameBegin(db.baseTxFrame())

    for i in 1..<10:
      let acc = makeAccount(i.uint64)
      check tx1.mergeAccountRecord(acc[0], acc[1]).isOk()
    tx1.checkpoint(1, skipSnapshot = false)

    let tx2 = db.txFrameBegin(tx1)
    for i in 1..<10:
      let acc = makeAccount(i.uint64)
      check tx2.mergeAccountRecord(acc[0], acc[1]).isOk()
    tx2.checkpoint(2, skipSnapshot = false)

    discard tx2.fetchStateRoot().get()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx2)
    check:
      db.putEndFn(batch).isOk()

  test "Get state root on a txFrame which has lower level than the baseTxFrame":
    # level 1
    let tx1 = db.txFrameBegin(db.baseTxFrame())
    for i in 1..<100:
      let acc = makeAccount(i.uint64)
      check tx1.mergeAccountRecord(acc[0], acc[1]).isOk()
    tx1.checkpoint(1, skipSnapshot = false)

    # level 2
    let tx2 = db.txFrameBegin(tx1)
    for i in 100..<200:
      let acc = makeAccount(i.uint64)
      check tx2.mergeAccountRecord(acc[0], acc[1]).isOk()
    tx2.checkpoint(2, skipSnapshot = false)

    # level 3
    let tx3 = db.txFrameBegin(tx2)
    for i in 200..<300:
      let acc = makeAccount(i.uint64)
      check tx3.mergeAccountRecord(acc[0], acc[1]).isOk()
    tx3.checkpoint(3, skipSnapshot = false)

    # level 2
    let tx4 = db.txFrameBegin(tx1)
    for i in 300..<400:
      let acc = makeAccount(i.uint64)
      check tx4.mergeAccountRecord(acc[0], acc[1]).isOk()
    tx4.checkpoint(2, skipSnapshot = false)

    block:
      let batch = db.putBegFn().expect("working batch")
      db.persist(batch, tx3) # after this the baseTxFrame is at level 3
      check:
        db.putEndFn(batch).isOk()

    # Verify that getting the state root of the level 3 txFrame does not impact
    # the persisted state in the database.
    let stateRootBefore = tx3.fetchStateRoot().get()
    expect(Defect):
      discard tx4.fetchStateRoot()
    let stateRootAfter = tx3.fetchStateRoot().get()
    check stateRootBefore == stateRootAfter
