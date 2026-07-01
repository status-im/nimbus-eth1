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

import results, unittest2, eth/common, ../execution_chain/db/core_db/memory_only

const
  # A fixed non-empty root distinct from EMPTY_ROOT_HASH, used as the key prefix.
  testRoot = hash32"0000000000000000000000000000000000000000000000000000000000000001"
  # crosses the 256-index boundary
  count = 300

suite "transactions / receipts storage (>256)":
  test "persistTransactions / getTransactions round-trips":
    let
      db = newCoreDbRef(AristoDbMemory)
      txFrame = db.baseTxFrame()

    var txs = newSeq[Transaction](count)
    for i in 0 ..< count:
      txs[i] = Transaction(nonce: AccountNonce(i))

    txFrame.persistTransactions(BlockNumber(1), testRoot, txs)

    let rc = txFrame.getTransactions(testRoot)
    require rc.isOk()
    let retrieved = rc.value

    check retrieved.len == count

    for i in 0 ..< count:
      check retrieved[i].nonce == AccountNonce(i)

  test "persistReceipts / getReceipts round-trips":
    let
      db = newCoreDbRef(AristoDbMemory)
      txFrame = db.baseTxFrame()

    var receipts = newSeq[StoredReceipt](count)
    for i in 0 ..< count:
      receipts[i] = StoredReceipt(cumulativeGasUsed: GasInt(i))

    txFrame.persistReceipts(testRoot, receipts)

    let rc = txFrame.getReceipts(testRoot)
    require rc.isOk()
    let retrieved = rc.value

    check retrieved.len == count
    for i in 0 ..< count:
      check retrieved[i].cumulativeGasUsed == GasInt(i)
