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
  eth/common,
  eth/rlp,
  ../execution_chain/db/core_db,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/storage_types,
  ../execution_chain/db/kvt,
  ../execution_chain/db/kvt/[kvt_init/memory_only, kvt_utils]

suite "Kvt TxFrame":
  setup:
    let db = KvtDbRef.init()

  test "Put overwrite data":
    check:
      db.put([byte 0, 1, 2], [byte 0, 1, 2]).isOk()
      db.put([byte 0, 1, 2], [byte 0, 1, 3]).isOk()

    check:
      db.get([byte 0, 1, 2]).expect("entry") == @[byte 0, 1, 3]

    db.close()

  test "Delete - delBe":
    check:
      db.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      db.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()
      db.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    check:
      db.delBe([byte 0, 1, 2]).isOk()
      db.get([byte 0, 1, 1]).expect("entry") == @[byte 0, 1, 4]
      not db.hasKey([byte 0, 1, 2])
      db.get([byte 0, 1, 3]).expect("entry") == @[byte 0, 1, 6]

    db.close()

  test "Delete range - delRangeBe":
    check:
      db.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      db.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()
      db.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    check:
      db.delRangeBe([byte 0, 1, 1], [byte 0, 1, 3], compactRange = false).isOk()
      not db.hasKey([byte 0, 1, 1])
      not db.hasKey([byte 0, 1, 2])
      db.get([byte 0, 1, 3]).expect("entry") == @[byte 0, 1, 6]

    db.close()

  test "MultiGet - multiGetBe":
    check:
      db.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      db.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()
      db.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

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
    check:
      db.put([byte 0, 1, 1], [byte 0, 1, 4]).isOk()
      db.put([byte 0, 1, 2], [byte 0, 1, 5]).isOk()

    check db.put([byte 0, 1, 3], [byte 0, 1, 6]).isOk()

    block:
      # test using seq inputs
      let keys = @[
        @[byte 0, 1, 1],
        @[byte 0, 1, 3],
        @[byte 0, 1, 4]
      ]
      var values = newSeq[Opt[seq[byte]]](keys.len())

      let r = db.multiGet(keys, values)
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

      let r = db.multiGet(keys, values)
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
