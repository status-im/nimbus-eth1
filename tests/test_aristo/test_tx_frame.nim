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
    aristo_init,
    aristo_init/memory_db,
    aristo_merge,
    aristo_persist,
  ]

proc makeAccount(i: uint64): (Hash32, AristoAccount) =
  var path: Hash32
  path.data()[0 .. 7] = i.toBytesBE()
  (path, AristoAccount(balance: i.u256, codeHash: EMPTY_CODE_HASH))

const
  acc1 = makeAccount(1)
  acc2 = makeAccount(2)

suite "Aristo TxFrame":
  setup:
    let
      mdb = MemDbRef()
      db = AristoDbRef.init(memoryBackend(mdb)).expect("working memory backend")

  test "Frames should independently keep data":
    let
      tx0 = db.txFrameBegin(db.baseTxFrame())
      tx1 = db.txFrameBegin(tx0)
      tx2 = db.txFrameBegin(tx1)
      tx2b = db.txFrameBegin(tx1)

    check:
      tx0.mergeAccountRecord(acc1[0], acc1[1]).isOk()
      tx1.mergeAccountRecord(acc2[0], acc2[1]).isOk()
      tx2.deleteAccountRecord(acc2[0]).isOk()
      tx2b.deleteAccountRecord(acc1[0]).isOk()

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

    tx2.checkpoint(1)
    let batch = db.backend.putBegFn().expect("working batch")
    db.persist(batch, tx2)
    check:
      db.backend.putEndFn(batch).isOk()

    db.finish()

    block:
      let
        db2 = AristoDbRef.init(memoryBackend(mdb)).expect("working backend")
        tx = db2.baseTxFrame()
      check:
        tx.fetchAccountRecord(acc1[0]).isOk()
        tx.fetchAccountRecord(acc2[0]).isErr() # Doesn't exist in tx2
