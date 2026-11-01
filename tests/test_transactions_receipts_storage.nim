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

import
  std/sequtils,
  results,
  unittest2,
  eth/[common, rlp],
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/utils/utils

func mixedTxs(n: int): seq[Transaction] =
  ## Transactions of every type, with varying sizes
  const types = [TxLegacy, TxEip2930, TxEip1559, TxEip4844, TxEip7702]
  for i in 0 ..< n:
    var tx = Transaction(
      txType: types[i mod types.len],
      chainId: 1.u256,
      nonce: AccountNonce(i),
      gasPrice: GasInt(i + 1),
      maxPriorityFeePerGas: GasInt(i),
      maxFeePerGas: GasInt(2 * i + 1),
      gasLimit: GasInt(21_000 + i),
      to: Opt.some(Address.copyFrom(newSeqWith(20, byte(i)))),
      value: i.u256,
      payload: newSeq[byte](i mod 50),
      V: uint64(i mod 2),
      R: (i + 1).u256,
      S: (i + 2).u256,
    )
    if tx.txType != TxLegacy:
      tx.accessList = @[AccessPair(
        address: Address.copyFrom(newSeqWith(20, byte(i + 1))),
        storageKeys: @[default(Bytes32)])]
    if tx.txType == TxEip4844:
      tx.maxFeePerBlobGas = 1.u256
      tx.versionedHashes = @[default(VersionedHash)]
    if tx.txType == TxEip7702:
      tx.authorizationList = @[Authorization(
        chainId: 1.u256, nonce: AccountNonce(i), r: 1.u256, s: 2.u256)]
    result.add tx

const
  # A fixed non-empty root distinct from EMPTY_ROOT_HASH, used as the key prefix.
  testRoot = hash32"0000000000000000000000000000000000000000000000000000000000000001"
  # crosses the 256-index boundary
  count = 300

suite "transactions / receipts storage (>256)":
  test "calcTxRootEncoded matches calcTxRoot":
    for n in [0, 1, 2, 5, 127, 128, 129, 300]:
      let txs = mixedTxs(n)
      check calcTxRootEncoded(txs.mapIt(rlp.encode(it))) == calcTxRoot(txs)

  test "persistEncodedTransactions matches persistTransactions":
    let
      db = newCoreDbRef(AristoDbMemory)
      txFrame = db.baseTxFrame()
      txs = mixedTxs(count)
      otherRoot = hash32"0000000000000000000000000000000000000000000000000000000000000002"
      hashes = txFrame.persistTransactions(BlockNumber(1), testRoot, txs)
      encodedHashes = txFrame.persistEncodedTransactions(
        BlockNumber(1), otherRoot, txs.mapIt(rlp.encode(it)))

    check hashes == encodedHashes
    check hashes == txs.mapIt(it.computeRlpHash)

    # Both procs must store identical bytes
    for i in 0 ..< count:
      let
        a = txFrame.getTransactionByIndex(testRoot, i.uint16)
        b = txFrame.getTransactionByIndex(otherRoot, i.uint16)
      require a.isOk() and b.isOk()
      check rlp.encode(a.value) == rlp.encode(b.value)
      check rlp.encode(b.value) == rlp.encode(txs[i])

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
