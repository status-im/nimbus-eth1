# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  chronos,
  results,
  stew/endians2,
  ../db/kvt/[kvt_desc, kvt_utils],
  ../db/storage_types,
  ../common

logScope:
  topics = "pruner"

# ------------------------------------------------------------------------------
# Direct-backend deletion helpers (bypass transaction layer)
# ------------------------------------------------------------------------------

proc deleteTransactionsBe(kvt: KvtDbRef, txRoot: Hash32) =
  if txRoot == EMPTY_ROOT_HASH:
    return

  kvt.delRangeBe(hashIndexKey(txRoot, 0), hashIndexKey(txRoot, uint16.high)).isOkOr:
    warn "pruner: deleteTransactionsBe", txRoot, error

proc deleteReceiptsBe(kvt: KvtDbRef, receiptsRoot: Hash32) =
  if receiptsRoot == EMPTY_ROOT_HASH:
    return

  kvt.delRangeBe(
    hashIndexKey(receiptsRoot, 0), hashIndexKey(receiptsRoot, uint16.high)
  ).isOkOr:
    warn "pruner: deleteReceiptsBe", receiptsRoot, error

proc deleteUnclesBe(kvt: KvtDbRef, ommersHash: Hash32) =
  if ommersHash == EMPTY_UNCLE_HASH:
    return
  kvt.delBe(genericHashKey(ommersHash).toOpenArray).isOkOr:
    warn "pruner: deleteUnclesBe", ommersHash, error

proc deleteWithdrawalsBe(kvt: KvtDbRef, withdrawalsRoot: Hash32) =
  if withdrawalsRoot == EMPTY_ROOT_HASH:
    return
  kvt.delBe(withdrawalsKey(withdrawalsRoot).toOpenArray).isOkOr:
    warn "pruner: deleteWithdrawalsBe", withdrawalsRoot, error

proc deleteBlockBodyAndReceiptsBe*(kvt: KvtDbRef, header: Header) =
  kvt.deleteTransactionsBe(header.transactionsRoot)
  kvt.deleteUnclesBe(header.ommersHash)
  if header.withdrawalsRoot.isSome:
    kvt.deleteWithdrawalsBe(header.withdrawalsRoot.get())
  kvt.deleteReceiptsBe(header.receiptsRoot)

proc deleteBlockAccessListsBe*(
    kvt: KvtDbRef, blockHashes: openArray[Hash32], tail: BlockNumber
) =
  let batch = kvt.putBegFn().expect("pruner: putBegFn")
  for blockHash in blockHashes:
    kvt.putKvpFn(
      batch, blockHashToBlockAccessListKey(blockHash).toOpenArray, default(seq[byte]))
  kvt.putKvpFn(batch, balPrunerStateKey().toOpenArray, tail.toBytesLE())
  kvt.putEndFn(batch).expect("pruner: putEndFn")


# ------------------------------------------------------------------------------
# Direct-backend progress tracking
# ------------------------------------------------------------------------------

proc setBlockNumberBe(kvt: KvtDbRef, key: DbKey, blockNumber: BlockNumber) =
  let
    value = blockNumber.toBytesLE()
    batch = kvt.putBegFn().expect("pruner: putBegFn")
  kvt.putKvpFn(batch, key.toOpenArray, value)
  kvt.putEndFn(batch).expect("pruner: putEndFn")

proc getBlockNumberBe(kvt: KvtDbRef, key: DbKey): BlockNumber =
  let blkNum = kvt.getBe(key.toOpenArray).valueOr:
    return BlockNumber(0)
  BlockNumber(uint64.fromBytesLE(blkNum))

proc setChainTailBe*(kvt: KvtDbRef, blockNumber: BlockNumber) =
  kvt.setBlockNumberBe(tailIdKey(), blockNumber)

proc getChainTailBe*(kvt: KvtDbRef): BlockNumber =
  kvt.getBlockNumberBe(tailIdKey())

proc setBalTailBe*(kvt: KvtDbRef, blockNumber: BlockNumber) =
  ## Records the block number up to which block access lists have been pruned.
  kvt.setBlockNumberBe(balPrunerStateKey(), blockNumber)

proc getBalTailBe*(kvt: KvtDbRef): BlockNumber =
  kvt.getBlockNumberBe(balPrunerStateKey())
