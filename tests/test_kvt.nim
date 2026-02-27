# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  results,
  ../execution_chain/db/kvt, ../execution_chain/db/kvt/[kvt_tx_frame, kvt_utils]

suite "Kvt TxFrame":
  setup:
    let db = KvtDbRef.init()

  test "Frames should independently keep data":
    let
      tx0 = db.txFrameBegin(db.baseTxFrame())
      tx1 = db.txFrameBegin(tx0)

    check:
      tx0.put([byte 0, 1, 2], [byte 0, 1, 2]).isOk()
      tx1.put([byte 0, 1, 2], [byte 0, 1, 3]).isOk()

    check:
      tx0.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 2]
      tx1.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx1)
    check:
      db.putEndFn(batch).isOk()

    block:
      # using the same backend but new txRef and cache
      let tx = db.baseTxFrame()
      check:
        tx.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]

    db.finish()

  test "Delete":
    let
      tx0 = db.txFrameBegin(db.baseTxFrame())

    check:
      tx0.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      tx0.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()
      tx0.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx0)
    check:
      db.putEndFn(batch).isOk()

    check db.delBe([byte 0, 1, 2]).isOk()

    block:
      # using the same backend but new txRef and cache
      let tx = db.baseTxFrame()
      check:
        tx.get([byte 0, 1, 1]).expect("entry") == @[byte 0, 1, 4]
        not tx.hasKey([byte 0, 1, 2])
        tx.get([byte 0, 1, 3]).expect("entry") == @[byte 0, 1, 6]

    db.finish()

  test "Delete range":
    let
      tx0 = db.txFrameBegin(db.baseTxFrame())

    check:
      tx0.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      tx0.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()
      tx0.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx0)
    check:
      db.putEndFn(batch).isOk()

    check db.delRangeBe([byte 0, 1, 1], [byte 0, 1, 3], compactRange = false).isOk()

    block:
      # using the same backend but new txRef and cache
      let tx = db.baseTxFrame()
      check:
        not tx.hasKey([byte 0, 1, 1])
        not tx.hasKey([byte 0, 1, 2])
        tx.get([byte 0, 1, 3]).expect("entry") == @[byte 0, 1, 6]

    db.finish()
