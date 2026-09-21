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
  std/tables,
  unittest2,
  results,
  eth/common,
  eth/rlp,
  ../execution_chain/db/core_db,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/storage_types,
  ../execution_chain/db/kvt,
  ../execution_chain/db/kvt/[kvt_init/memory_only, kvt_tx_frame, kvt_utils]

suite "Kvt write set":
  setup:
    let db = KvtDbRef.init()

  test "Write sets are independent and do not cascade":
    let
      tx0 = db.txFrameBegin()
      tx1 = db.txFrameBegin()

    check:
      tx0.put([byte 0, 1, 2], [byte 0, 1, 2]).isOk()
      tx1.put([byte 0, 1, 2], [byte 0, 1, 3]).isOk()

    check:
      tx0.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 2]
      tx1.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]
      # A write set only ever sees its own writes and the backend.
      tx0.get([byte 0, 1, 9]).isErr()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx1)
    check:
      db.putEndFn(batch).isOk()

    check:
      # `tx1` was flushed and is empty again; its data is now on the backend.
      tx1.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]
      db.baseTxFrame().get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]
      # `tx0` was never persisted, and still shadows the backend with its own
      # pending value.
      tx0.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 2]

    tx0.dispose()
    check db.baseTxFrame().get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]

    db.close()

  test "A discarded write set never reaches the backend":
    let tx = db.txFrameBegin()
    check tx.put([byte 0, 1, 2], [byte 0, 1, 2]).isOk()
    tx.dispose()

    check db.getBe([byte 0, 1, 2]).isErr()

    db.close()

  test "persist writes a stand-alone write set in its own batch":
    let tx = db.txFrameBegin()
    check tx.put([byte 0, 1, 2], [byte 0, 1, 7]).isOk()

    tx.persist()

    check:
      len(tx.sTab) == 0
      db.getBe([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 7]

    db.close()

  test "persist also flushes what was written to the base write set":
    let
      base = db.baseTxFrame()
      tx = db.txFrameBegin()

    check:
      base.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      tx.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx)
    check db.putEndFn(batch).isOk()

    check:
      db.getBe([byte 0, 1, 1]).expect("entry") == @[byte 0, 1, 4]
      db.getBe([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 5]
      # The persisted write set has taken over as the base.
      db.baseTxFrame() == tx

    db.close()

  test "Delete - delBe":
    let
      tx0 = db.txFrameBegin()

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

    db.close()

  test "Delete range - delRangeBe":
    let
      tx0 = db.txFrameBegin()

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

    db.close()

  test "MultiGet - multiGetBe":
    let
      tx0 = db.txFrameBegin()

    check:
      tx0.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      tx0.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()
      tx0.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx0)
    check:
      db.putEndFn(batch).isOk()

    block:
      # test using seq inputs
      let keys = @[
        @[byte 0, 1, 1],
        @[byte 0, 1, 2],
        @[byte 0, 1, 4]
      ]
      var values = newSeq[Opt[seq[byte]]](keys.len())

      let r = db.multiGetBe(keys, values)
      check:
        r.isOk()
        values[0] == Opt.some(@[byte 0, 1, 4])
        values[1] == Opt.some(@[byte 0, 1, 5])
        values[2] == Opt.none(seq[byte])

    block:
      # test using array inputs
      let keys = [
        @[byte 0, 1, 1],
        @[byte 0, 1, 2],
        @[byte 0, 1, 4]
      ]
      var values: array[3, Opt[seq[byte]]]

      let r = db.multiGetBe(keys, values)
      check:
        r.isOk()
        values[0] == Opt.some(@[byte 0, 1, 4])
        values[1] == Opt.some(@[byte 0, 1, 5])
        values[2] == Opt.none(seq[byte])

    db.close()

  test "MultiGet - multiGet":
    let
      tx0 = db.txFrameBegin()

    check:
      tx0.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      tx0.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()

    let batch = db.putBegFn().expect("working batch")
    db.persist(batch, tx0)
    check:
      db.putEndFn(batch).isOk()

    let tx1 = db.txFrameBegin()
    check tx1.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    block:
      # test using seq inputs
      let keys = @[
        @[byte 0, 1, 1],
        @[byte 0, 1, 3],
        @[byte 0, 1, 4]
      ]
      var values = newSeq[Opt[seq[byte]]](keys.len())

      let r = tx1.multiGet(keys, values)
      check:
        r.isOk()
        values[0] == Opt.some(@[byte 0, 1, 4])
        values[1] == Opt.some(@[byte 0, 1, 6])
        values[2] == Opt.none(seq[byte])

    block:
      # test using array inputs
      let keys = [
        @[byte 0, 1, 1],
        @[byte 0, 1, 3],
        @[byte 0, 1, 4]
      ]
      var values: array[3, Opt[seq[byte]]]

      let r = tx1.multiGet(keys, values)
      check:
        r.isOk()
        values[0] == Opt.some(@[byte 0, 1, 4])
        values[1] == Opt.some(@[byte 0, 1, 6])
        values[2] == Opt.none(seq[byte])

    db.close()

suite "Kvt block hash cache":
  const
    hashA = hash32"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    hashB = hash32"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  setup:
    let db = newCoreDbRef(DefaultDbMemory, enableCaches = true)

  test "Persisted block hashes are served from the cache":
    let base = db.baseTxFrame()
    base.addBlockNumberToHashLookup(BlockNumber(1), hashA)
    db.persist(base)

    check:
      db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA
      db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA

    db.kvt.delBe(blockNumberToHashKey(BlockNumber(1)).toOpenArray).expect("del")
    check db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA

    db.close()

  test "Frame writes take precedence over the cache":
    let base = db.baseTxFrame()
    base.addBlockNumberToHashLookup(BlockNumber(1), hashA)
    db.persist(base)

    check db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA

    let fork = db.txFrameBegin()
    fork.addBlockNumberToHashLookup(BlockNumber(1), hashB)

    check:
      fork.getBlockHash(BlockNumber(1)).expect("hash") == hashB
      db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA

    db.close()

  test "Persisting a new block hash updates the cache in place":
    let base = db.baseTxFrame()
    base.addBlockNumberToHashLookup(BlockNumber(1), hashA)
    db.persist(base)

    check db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA

    let fork = db.txFrameBegin()
    fork.addBlockNumberToHashLookup(BlockNumber(1), hashB)
    fork.checkpoint(BlockNumber(1))
    db.persist(fork)

    db.kvt.delBe(blockNumberToHashKey(BlockNumber(1)).toOpenArray).expect("del")
    check db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashB

    db.close()

  test "Persisting inserts an uncached block hash into the cache":
    let base = db.baseTxFrame()
    base.addBlockNumberToHashLookup(BlockNumber(2), hashB)
    db.persist(base)

    db.kvt.delBe(blockNumberToHashKey(BlockNumber(2)).toOpenArray).expect("del")
    check db.baseTxFrame().getBlockHash(BlockNumber(2)).expect("hash") == hashB

    db.close()

  test "A read miss fills the cache from the backend":
    let batch = db.kvt.putBegFn().expect("batch")
    db.kvt.putKvpFn(
      batch, blockNumberToHashKey(BlockNumber(7)).toOpenArray, rlp.encode(hashA))
    db.kvt.putEndFn(batch).expect("putEndFn")

    check db.baseTxFrame().getBlockHash(BlockNumber(7)).expect("hash") == hashA

    db.kvt.delBe(blockNumberToHashKey(BlockNumber(7)).toOpenArray).expect("del")
    check db.baseTxFrame().getBlockHash(BlockNumber(7)).expect("hash") == hashA

    db.close()

  test "A deleted block hash is not resurrected by the cache":
    let base = db.baseTxFrame()
    base.addBlockNumberToHashLookup(BlockNumber(1), hashA)
    db.persist(base)

    check db.baseTxFrame().getBlockHash(BlockNumber(1)).expect("hash") == hashA

    let deleting = db.txFrameBegin()
    deleting.del(blockNumberToHashKey(BlockNumber(1)).toOpenArray).expect("del")
    deleting.checkpoint(BlockNumber(1))
    db.persist(deleting)

    check db.baseTxFrame().getBlockHash(BlockNumber(1)).isErr()

    db.close()
