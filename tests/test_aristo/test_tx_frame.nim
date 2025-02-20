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
        tx2c.layersGetVtx((VertexID(1), acc1Hike.legs[^1].wp.vid)).value()[1]
      ) == 1

    tx0.checkpoint(1)
    tx1.checkpoint(2)
    tx2.checkpoint(3)
    tx2b.checkpoint(3)
    tx2c.checkpoint(3)

    check:
      # Even after checkpointing, we should maintain the same relative levels
      (
        tx2c.level -
        tx2c.layersGetVtx((VertexID(1), acc1Hike.legs[^1].wp.vid)).value()[1]
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
