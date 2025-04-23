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
  results,
  ../execution_chain/db/kvt, ../execution_chain/db/kvt/[kvt_tx_frame, kvt_utils]

suite "Kvt TxFrame":
  setup:
    let db = KvtDbRef.init()

  test "Frames should independently keep data":
    let
      tx0 = db.txFrameBegin(db.baseTxFrame())
      tx1 = db.txFrameBegin(tx0)
      tx2 = db.txFrameBegin(tx1)
      tx2b = db.txFrameBegin(tx1)
      tx2c = db.txFrameBegin(tx1)

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

    db.finish()

    block:
      # using the same backend but new txRef and cache
      let tx = db.baseTxFrame()
      check:
        tx.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]
