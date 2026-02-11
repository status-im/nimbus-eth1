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
  eth/common/times,
  ./db/core_db,
  ./common

logScope:
  topic = "pruner"

const
  RetentionPeriod = 6 * 30 * 24 * 60 * 60'u64 # ~6 months in seconds

type
  BackgroundPrunerRef* = ref object
    com: CommonRef
    batchSize: uint64
    batchDelay: chronos.Duration
    loopDelay: chronos.Duration
    loopFut: Future[void].Raising([CancelledError])

proc init*(
    T: type BackgroundPrunerRef,
    com: CommonRef,
    batchSize = 150'u64,
    batchDelay = chronos.milliseconds(10),
    loopDelay = chronos.seconds(60),
): T =
  T(
    com: com,
    batchSize: batchSize,
    batchDelay: batchDelay,
    loopDelay: loopDelay,
  )

proc pruneLoop(pruner: BackgroundPrunerRef) {.async: (raises: [CancelledError]).} =
  while true:
    let
      baseTx = pruner.com.db.baseTxFrame()
      start = baseTx.getSavedStateBlockNumber()
      begin = baseTx.getHistoryExpired()
      cutoff = EthTime(EthTime.now().uint64 - RetentionPeriod)

    if begin >= start:
      await sleepAsync(pruner.loopDelay)
      continue

    notice "Background pruner: starting cycle",
      fromBlock = begin, toBlock = start, cutoffTimestamp = cutoff.uint64

    var currentBlock = begin
    var reachedRetentionWindow = false

    while currentBlock <= start and not reachedRetentionWindow:
      var txFrame = pruner.com.db.baseTxFrame().txFrameBegin()
      let batchEnd = min(currentBlock + pruner.batchSize - 1, start)
      var lastPruned = currentBlock

      for blkNum in currentBlock .. batchEnd:
        let header = baseTx.getBlockHeader(blkNum).valueOr:
          warn "Background pruner: failed to get header",
            blkNum = blkNum, error = error
          continue
        if header.timestamp >= cutoff:
          reachedRetentionWindow = true
          break
        txFrame.deleteBlockBodyAndReceipts(blkNum).isOkOr:
          warn "Background pruner: failed to delete",
            blkNum = blkNum, error = error
        lastPruned = blkNum + 1

      txFrame.setHistoryExpired(lastPruned)
      txFrame.checkpoint(start, skipSnapshot = true)
      pruner.com.db.persist(txFrame)

      notice "Background pruner: batch persisted",
        blks = lastPruned

      currentBlock = lastPruned
      await sleepAsync(pruner.batchDelay)

    notice "Background pruner: cycle complete",
      prunedUpTo = currentBlock

    await sleepAsync(pruner.loopDelay)

proc start*(pruner: BackgroundPrunerRef) =
  pruner.loopFut = pruner.pruneLoop()

proc stop*(pruner: BackgroundPrunerRef) {.async: (raises: []).} =
  if not pruner.loopFut.isNil:
    await noCancel pruner.loopFut.cancelAndWait()
