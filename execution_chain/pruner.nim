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
  std/times,
  chronicles,
  chronos,
  results,
  stew/endians2,
  eth/common/times,
  ./db/core_db,
  ./db/kvt/[kvt_desc, kvt_utils],
  ./db/storage_types,
  ./common

logScope:
  topics = "pruner"

const
  # MIN_EPOCHS_FOR_BLOCK_REQUESTS (33,024) * SLOTS_PER_EPOCH (32) * SECONDS_PER_SLOT (12)
  RetentionPeriod = 33_024'u64 * 32 * 12

type
  BackgroundPrunerRef* = ref object
    com: CommonRef
    batchSize: uint64
    loopDelay: chronos.Duration
    loopFut: Future[void].Raising([CancelledError])

# ------------------------------------------------------------------------------
# Direct-backend deletion helpers (bypass transaction layer)
# ------------------------------------------------------------------------------

proc deleteTransactionsBe(kvt: KvtDbRef, txRoot: Hash32) =
  if txRoot == EMPTY_ROOT_HASH: return
  kvt.delRangeBe(hashIndexKey(txRoot, 0), hashIndexKey(txRoot, uint16.high),
    compactRange = true).isOkOr:
    warn "pruner: deleteTransactionsBe", txRoot, error

proc deleteReceiptsBe(kvt: KvtDbRef, receiptsRoot: Hash32) =
  if receiptsRoot == EMPTY_ROOT_HASH: return
  kvt.delRangeBe(hashIndexKey(receiptsRoot, 0), hashIndexKey(receiptsRoot, uint16.high),
    compactRange = true).isOkOr:
    warn "pruner: deleteReceiptsBe", receiptsRoot, error

proc deleteUnclesBe(kvt: KvtDbRef, ommersHash: Hash32) =
  if ommersHash == EMPTY_UNCLE_HASH: return
  kvt.delBe(genericHashKey(ommersHash).toOpenArray).isOkOr:
    warn "pruner: deleteUnclesBe", ommersHash, error

proc deleteWithdrawalsBe(kvt: KvtDbRef, withdrawalsRoot: Hash32) =
  if withdrawalsRoot == EMPTY_ROOT_HASH: return
  kvt.delBe(withdrawalsKey(withdrawalsRoot).toOpenArray).isOkOr:
    warn "pruner: deleteWithdrawalsBe", withdrawalsRoot, error

proc deleteBlockBodyAndReceiptsBe(kvt: KvtDbRef, header: Header) =
  kvt.deleteTransactionsBe(header.transactionsRoot)
  kvt.deleteUnclesBe(header.ommersHash)
  if header.withdrawalsRoot.isSome:
    kvt.deleteWithdrawalsBe(header.withdrawalsRoot.get())
  kvt.deleteReceiptsBe(header.receiptsRoot)

# ------------------------------------------------------------------------------
# Direct-backend progress tracking
# ------------------------------------------------------------------------------

proc setChainTailBe(kvt: KvtDbRef, blockNumber: BlockNumber) =
  let
    key = tailIdKey()
    value = blockNumber.toBytesLE()
    batch = kvt.putBegFn().expect("pruner: putBegFn")
  kvt.putKvpFn(batch, key.toOpenArray, value)
  kvt.putEndFn(batch).expect("pruner: putEndFn")

proc getChainTailBe(kvt: KvtDbRef): BlockNumber =
  let blkNum = kvt.getBe(tailIdKey().toOpenArray).valueOr:
    return BlockNumber(0)
  BlockNumber(uint64.fromBytesLE(blkNum))

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

proc init*(
    T: type BackgroundPrunerRef,
    com: CommonRef,
    batchSize = 100'u64,
    loopDelay = chronos.seconds(12),
): T =
  T(com: com, batchSize: batchSize, loopDelay: loopDelay)

proc pruneLoop(pruner: BackgroundPrunerRef) {.async: (raises: [CancelledError]).} =
  info "Starting pruner"
  let kvt = pruner.com.db.kvt
  while true:
    let
      baseTx = pruner.com.db.baseTxFrame()
      head = baseTx.getSavedStateBlockNumber()
      tail = kvt.getChainTailBe()
      cutoff = EthTime(getTime().toUnix.uint64 - RetentionPeriod)

    debug "Pruner status", head, tail, cutoffTimestamp = distinctBase(cutoff)

    if tail >= head:
      await sleepAsync(pruner.loopDelay)
      continue

    var
      currentBlock = tail
      blocksSinceSave = 0'u64
      lastLogTime = Moment.now()

    while currentBlock <= head:
      let
        header = pruner.com.db.baseTxFrame.getBlockHeader(currentBlock).valueOr:
          warn "Background pruner: failed to get header",
            blkNum = currentBlock, error
          break
      if header.timestamp >= cutoff:
        break

      kvt.deleteBlockBodyAndReceiptsBe(header)
      currentBlock += 1
      blocksSinceSave += 1

      if blocksSinceSave >= pruner.batchSize:
        kvt.setChainTailBe(currentBlock)
        blocksSinceSave = 0

        debug "Background pruner: batch complete", blks = currentBlock

        if Moment.now() - lastLogTime >= chronos.seconds(12):
          info "Pruning history",
            tail = currentBlock,
            head = pruner.com.db.baseTxFrame().getSavedStateBlockNumber(),
            pruned = currentBlock - tail
          lastLogTime = Moment.now()

        await sleepAsync(chronos.seconds(2))

    # Save final progress (covers partial batch at end / before break)
    if currentBlock > tail:
      kvt.setChainTailBe(currentBlock)

    notice "Pruning cycle completed", prunedUpTo = currentBlock

    await sleepAsync(pruner.loopDelay)

proc start*(pruner: BackgroundPrunerRef) =
  pruner.loopFut = pruner.pruneLoop()

proc stop*(pruner: BackgroundPrunerRef) {.async: (raises: []).} =
  if not pruner.loopFut.isNil:
    await pruner.loopFut.cancelAndWait()
