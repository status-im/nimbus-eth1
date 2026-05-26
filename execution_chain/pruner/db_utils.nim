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

  kvt.delRangeBe(
    hashIndexKey(txRoot, 0), hashIndexKey(txRoot, uint16.high), compactRange = true
  ).isOkOr:
    warn "pruner: deleteTransactionsBe", txRoot, error

proc deleteReceiptsBe(kvt: KvtDbRef, receiptsRoot: Hash32) =
  if receiptsRoot == EMPTY_ROOT_HASH:
    return

  kvt.delRangeBe(
    hashIndexKey(receiptsRoot, 0),
    hashIndexKey(receiptsRoot, uint16.high),
    compactRange = true,
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

# ------------------------------------------------------------------------------
# Direct-backend progress tracking
# ------------------------------------------------------------------------------

proc setChainTailBe*(kvt: KvtDbRef, blockNumber: BlockNumber) =
  let
    key = tailIdKey()
    value = blockNumber.toBytesLE()
    batch = kvt.putBegFn().expect("pruner: putBegFn")
  kvt.putKvpFn(batch, key.toOpenArray, value)
  kvt.putEndFn(batch).expect("pruner: putEndFn")

proc getChainTailBe*(kvt: KvtDbRef): BlockNumber =
  let blkNum = kvt.getBe(tailIdKey().toOpenArray).valueOr:
    return BlockNumber(0)
  BlockNumber(uint64.fromBytesLE(blkNum))
