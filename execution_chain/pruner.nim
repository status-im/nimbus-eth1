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
    batchSize = 10'u64,
    batchDelay = chronos.milliseconds(20),
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

    # TODO: timestamp based check
    if begin >= start:
      await sleepAsync(pruner.loopDelay)
      continue

    notice "Background pruner: starting cycle",
      fromBlock = begin, toBlock = start, cutoffTimestamp = cutoff.uint64

    var currentBlock = begin
    # TODO: Update retention Window calculation
    var reachedRetentionWindow = false

    while currentBlock <= start and not reachedRetentionWindow:
      # Re-read baseTxFrame each iteration — FC's persist may have replaced it
      let baseTx = pruner.com.db.baseTxFrame()
      let batchEnd = min(currentBlock + pruner.batchSize - 1, start)
      var lastPruned = currentBlock

      # No await points in this loop body — atomic from the async perspective.
      # Deletions accumulate in baseTx's in-memory sTab and get written to disk
      # when the ForkedChain next calls persist. We must NOT call persist()
      # ourselves as it replaces the base frame reference, causing SIGSEGV in
      # concurrent async tasks (engine API, sync) that hold the old reference.
      for blkNum in currentBlock .. batchEnd:
        let header = baseTx.getBlockHeader(blkNum).valueOr:
          warn "Background pruner: failed to get header",
            blkNum = blkNum, error = error
          continue
        if header.timestamp >= cutoff:
          reachedRetentionWindow = true
          break
        baseTx.deleteBlockBodyAndReceipts(blkNum).isOkOr:
          warn "Background pruner: failed to delete",
            blkNum = blkNum, error = error
        lastPruned = blkNum + 1

      baseTx.setHistoryExpired(lastPruned)

      notice "Background pruner: batch complete",
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
