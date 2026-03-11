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
    compactRange = false).isOkOr:
    warn "pruner: deleteTransactionsBe", txRoot, error

proc deleteReceiptsBe(kvt: KvtDbRef, receiptsRoot: Hash32) =
  if receiptsRoot == EMPTY_ROOT_HASH: return
  kvt.delRangeBe(hashIndexKey(receiptsRoot, 0), hashIndexKey(receiptsRoot, uint16.high),
    compactRange = false).isOkOr:
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

proc setHistoryExpiredBe(kvt: KvtDbRef, blockNumber: BlockNumber) =
  let
    key = historyExpiryIdKey()
    value = blockNumber.toBytesLE()
    batch = kvt.putBegFn().expect("pruner: putBegFn")
  kvt.putKvpFn(batch, key.toOpenArray, value)
  kvt.putEndFn(batch).expect("pruner: putEndFn")

proc getHistoryExpiredBe(kvt: KvtDbRef): BlockNumber =
  let blkNum = kvt.getBe(historyExpiryIdKey().toOpenArray).valueOr:
    return BlockNumber(0)
  BlockNumber(uint64.fromBytesLE(blkNum))

# ------------------------------------------------------------------------------
# Compaction helper
# ------------------------------------------------------------------------------

proc compactDeletedRanges(kvt: KvtDbRef, header: Header) =
  ## Trigger RocksDB compaction for ranges deleted in recent batches.
  ## Called once every 4 batches to amortize I/O cost.
  if header.transactionsRoot != EMPTY_ROOT_HASH:
    kvt.delRangeBe(hashIndexKey(header.transactionsRoot, 0),
      hashIndexKey(header.transactionsRoot, uint16.high),
      compactRange = true).isOkOr: discard
  if header.receiptsRoot != EMPTY_ROOT_HASH:
    kvt.delRangeBe(hashIndexKey(header.receiptsRoot, 0),
      hashIndexKey(header.receiptsRoot, uint16.high),
      compactRange = true).isOkOr: discard

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

proc init*(
    T: type BackgroundPrunerRef,
    com: CommonRef,
    batchSize = 250'u64,
    loopDelay = chronos.seconds(12),
): T =
  T(com: com, batchSize: batchSize, loopDelay: loopDelay)

proc pruneLoop(pruner: BackgroundPrunerRef) {.async: (raises: [CancelledError]).} =
  let kvt = pruner.com.db.kvt
  while true:
    let
      baseTx = pruner.com.db.baseTxFrame()
      start = baseTx.getSavedStateBlockNumber()
      begin = kvt.getHistoryExpiredBe()
      cutoff = EthTime(getTime().toUnix.uint64 - RetentionPeriod)

    if begin >= start:
      await sleepAsync(pruner.loopDelay)
      continue

    debug "Background pruner: starting cycle",
      fromBlock = begin, toBlock = start, cutoffTimestamp = distinctBase(cutoff)

    var
      currentBlock = begin
      reachedRetentionWindow = false
      batchCount = 0'u64
      lastLogTime = Moment.now()

    while currentBlock <= start and not reachedRetentionWindow:
      let batchEnd = min(currentBlock + pruner.batchSize - 1, start)
      var lastPruned = currentBlock
      let baseTx = pruner.com.db.baseTxFrame()

      # No await points — atomic from async perspective.
      # Deletions go directly to RocksDB backend via delBe/delRangeBe.
      for blkNum in currentBlock .. batchEnd:
        let header = baseTx.getBlockHeader(blkNum).valueOr:
          warn "Background pruner: failed to get header", blkNum = blkNum, error = error
          continue
        if header.timestamp >= cutoff:
          reachedRetentionWindow = true
          break
        kvt.deleteBlockBodyAndReceiptsBe(header)
        lastPruned = blkNum + 1

      kvt.setHistoryExpiredBe(lastPruned)
      inc batchCount

      # Trigger RocksDB compaction once every 4 batches
      if batchCount mod 4 == 0:
        let lastHeader = baseTx.getBlockHeader(lastPruned - 1).valueOr:
          Header()
        kvt.compactDeletedRanges(lastHeader)

      debug "Background pruner: batch complete", blks = lastPruned

      # Periodic status report (every 12 seconds)
      if Moment.now() - lastLogTime >= chronos.seconds(12):
        notice "Pruning history",
          tail = currentBlock,
          head = pruner.com.db.baseTxFrame().getSavedStateBlockNumber(),
          pruned = currentBlock - begin
        lastLogTime = Moment.now()

      currentBlock = lastPruned

      # Yield to event loop between batches
      await sleepAsync(chronos.seconds(1))

    debug "Background pruner: cycle complete", prunedUpTo = currentBlock

    await sleepAsync(pruner.loopDelay)

proc start*(pruner: BackgroundPrunerRef) =
  pruner.loopFut = pruner.pruneLoop()

proc stop*(pruner: BackgroundPrunerRef) {.async: (raises: []).} =
  if not pruner.loopFut.isNil:
    await pruner.loopFut.cancelAndWait()
