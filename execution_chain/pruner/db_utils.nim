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

proc deleteTransactionsBe(kvt: KvtDbRef, txRoot: Hash32): bool =
  if txRoot == EMPTY_ROOT_HASH:
    return true

  kvt.delRangeBe(
    hashIndexKey(txRoot, 0), hashIndexKey(txRoot, uint16.high), compactRange = true
  ).isOkOr:
    warn "pruner: deleteTransactionsBe", txRoot, error
    return false

  true

proc deleteReceiptsBe(kvt: KvtDbRef, receiptsRoot: Hash32): bool =
  if receiptsRoot == EMPTY_ROOT_HASH:
    return true

  kvt.delRangeBe(
    hashIndexKey(receiptsRoot, 0),
    hashIndexKey(receiptsRoot, uint16.high),
    compactRange = true,
  ).isOkOr:
    warn "pruner: deleteReceiptsBe", receiptsRoot, error
    return false

  true

proc deleteUnclesBe(kvt: KvtDbRef, ommersHash: Hash32): bool =
  if ommersHash == EMPTY_UNCLE_HASH:
    return true

  kvt.delBe(genericHashKey(ommersHash).toOpenArray).isOkOr:
    warn "pruner: deleteUnclesBe", ommersHash, error
    return false

  true

proc deleteWithdrawalsBe(kvt: KvtDbRef, withdrawalsRoot: Hash32): bool =
  if withdrawalsRoot == EMPTY_ROOT_HASH:
    return true

  kvt.delBe(withdrawalsKey(withdrawalsRoot).toOpenArray).isOkOr:
    warn "pruner: deleteWithdrawalsBe", withdrawalsRoot, error
    return false

  true

proc deleteBlockBodyAndReceiptsBe*(kvt: KvtDbRef, header: Header): bool =
  if not kvt.deleteTransactionsBe(header.transactionsRoot):
    return false
  if not kvt.deleteUnclesBe(header.ommersHash):
    return false
  if header.withdrawalsRoot.isSome:
    if not kvt.deleteWithdrawalsBe(header.withdrawalsRoot.get()):
      return false
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
