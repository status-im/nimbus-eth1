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
  eth/common/times,
  ./pruner/[db_utils, serialize],
  ./common

export serialize

logScope:
  topics = "pruner"

const
  # MIN_EPOCHS_FOR_BLOCK_REQUESTS (33,024) * SLOTS_PER_EPOCH (32) * SECONDS_PER_SLOT (12)
  RetentionPeriod* = 33_024'u64 * 32 * 12

type
  BackgroundPrunerRef* = ref object
    com: CommonRef
    batchSize: uint64
    loopDelay: chronos.Duration
    loopFut: Future[void].Raising([CancelledError])
    state*: PrunerState

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

proc init*(
    T: type BackgroundPrunerRef,
    com: CommonRef,
    batchSize = 100'u64,
    loopDelay = chronos.seconds(12),
): T =
  var state = com.db.kvt.loadPrunerStateBe()
  state.active = true
  T(
    com: com,
    batchSize: batchSize,
    loopDelay: loopDelay,
    state: state
  )

proc pruneLoop(pruner: BackgroundPrunerRef) {.async: (raises: [CancelledError]).} =
  info "Starting pruner"
  let
    kvt = pruner.com.db.kvt
    _ = kvt.loadPrunerStateBe()

  while true:
    let
      baseTx = pruner.com.db.baseTxFrame()
      cutoff = EthTime(getTime().toUnix.uint64 - RetentionPeriod)
      tail = kvt.getChainTailBe()

    pruner.state.head = baseTx.getSavedStateBlockNumber()
    pruner.state.tail = tail

    var
      currentBlock = pruner.state.tail
      blocksSinceSave = 0'u64
      lastLogTime = Moment.now()

    debug "Pruner status",
      head = pruner.state.head,
      tail = pruner.state.tail,
      cutoffTimestamp = distinctBase(cutoff)

    if pruner.state.tail >= pruner.state.head:
      await sleepAsync(pruner.loopDelay)
      continue

    while currentBlock <= pruner.state.head:
      let header = pruner.com.db.baseTxFrame.getBlockHeader(currentBlock).valueOr:
        warn "Background pruner: failed to get header", blkNum = currentBlock, error
        break
      if header.timestamp >= cutoff:
        break

      if not kvt.deleteBlockBodyAndReceiptsBe(header):
        warn "Background pruner: failed to delete block data",
          blkNum = currentBlock
        break

      currentBlock += 1
      blocksSinceSave += 1

      if blocksSinceSave >= pruner.batchSize:
        kvt.setChainTailBe(currentBlock)
        pruner.state.tail = currentBlock
        blocksSinceSave = 0

        debug "Background pruner: batch complete", blks = currentBlock

        if Moment.now() - lastLogTime >= chronos.seconds(12):
          info "Pruning history",
            tail = pruner.state.tail,
            head = pruner.com.db.baseTxFrame().getSavedStateBlockNumber(),
            pruned = pruner.state.tail - tail
          lastLogTime = Moment.now()

        await sleepAsync(chronos.seconds(2))

    # Save final progress (covers partial batch at end / before break)
    if currentBlock > pruner.state.tail:
      kvt.setChainTailBe(currentBlock)
      pruner.state.tail = currentBlock

    notice "Pruning cycle completed", prunedUpTo = currentBlock

    await sleepAsync(pruner.loopDelay)

proc start*(pruner: BackgroundPrunerRef) =
  pruner.loopFut = pruner.pruneLoop()

proc stop*(pruner: BackgroundPrunerRef) {.async: (raises: []).} =
  if not pruner.loopFut.isNil:
    await pruner.loopFut.cancelAndWait()
  pruner.com.db.kvt.savePrunerStateBe(pruner.state)
