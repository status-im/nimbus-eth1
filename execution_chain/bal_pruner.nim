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
  ./block_access_list/bal_utils,
  ./db/core_db,
  ./pruner/db_utils,
  ./common

logScope:
  topics = "bal pruner"

type
  BalPrunerRef* = ref object
    com: CommonRef
    batchSize: uint64
    loopDelay: chronos.Duration
    loopFut: Future[void].Raising([CancelledError])

proc findFirstBalBlock(txFrame: CoreDbTxRef, head: BlockNumber): Opt[BlockNumber] =
  # TODO: Once snap sync is implemented we should start from the beginning of history
  # instead of from genesis (block 0)
  var
    lo = BlockNumber(0)
    hi = head
    found = Opt.none(BlockNumber)

  while lo <= hi:
    let
      mid = lo + (hi - lo) div 2
      header = txFrame.getBlockHeader(mid).valueOr:
        warn "Skipping block with an unreadable header", blkNum = mid, error
        lo = mid + 1
        continue

    if header.blockAccessListHash.isSome():
      found = Opt.some(mid)
      if mid == 0:
        break
      hi = mid - 1
    else:
      lo = mid + 1

  found

proc findRetentionCutoff(
    txFrame: CoreDbTxRef, tail: BlockNumber, head: BlockNumber, headSlot: uint64
): BlockNumber =
  var
    lo = tail
    hi = head

  while lo <= hi:
    let
      mid = lo + (hi - lo) div 2
      header = txFrame.getBlockHeader(mid).valueOr:
        if mid == 0:
          return 0
        hi = mid - 1
        continue

    if header.isWithinBalRetentionPeriod(headSlot):
      if mid == 0:
        return 0
      hi = mid - 1
    else:
      lo = mid + 1

  lo

proc prune*(
    pruner: BalPrunerRef, head: BlockNumber, headSlot: uint64
): Future[uint64] {.async: (raises: [CancelledError]).} =

  let kvt = pruner.com.db.kvt

  var
    txFrame = pruner.com.db.baseTxFrame()
    tail = kvt.getBalTailBe()

  if tail == 0:
    tail = findFirstBalBlock(txFrame, head).valueOr:
      return 0
    kvt.setBalTailBe(tail)

  let header = txFrame.getBlockHeader(tail)
  if header.isOk() and header[].isWithinBalRetentionPeriod(headSlot):
    return 0

  let cutoff = findRetentionCutoff(txFrame, tail, head, headSlot)

  var
    currentBlock = tail
    pruned = 0'u64
    blockHashes = newSeqOfCap[Hash32](pruner.batchSize.int)

  while currentBlock < cutoff:
    let batchEnd = min(cutoff, currentBlock + pruner.batchSize)

    blockHashes.setLen(0)
    while currentBlock < batchEnd:
      let blockHash = txFrame.getBlockHash(currentBlock).valueOr:
        warn "Failed to get block hash", blkNum = currentBlock, error
        currentBlock += 1
        continue
      blockHashes.add blockHash
      currentBlock += 1

    kvt.deleteBlockAccessListsBe(blockHashes, currentBlock)
    pruned += blockHashes.len.uint64

    if currentBlock < cutoff:
      await sleepAsync(chronos.milliseconds(100))
      txFrame = pruner.com.db.baseTxFrame()

  if currentBlock == tail:
    warn "Skipping block with an unreadable header", blkNum = currentBlock
    currentBlock += 1
    kvt.setBalTailBe(currentBlock)

  if pruned > 0:
    info "Pruned block access lists", pruned, tail = currentBlock, head

  pruned

proc pruneCycle*(pruner: BalPrunerRef) {.async: (raises: [CancelledError]).} =
  let
    txFrame = pruner.com.db.baseTxFrame()
    headNumber = txFrame.getSavedStateBlockNumber()
    headHeader = txFrame.getBlockHeader(headNumber).valueOr:
      warn "Failed to get head header", blkNum = headNumber, error
      return

    headSlot = headHeader.slotNumber.valueOr:
      if pruner.com.isAmsterdamOrLater(headHeader.timestamp):
        warn "Head header is missing its slot number", blkNum = headNumber
      return

  discard await pruner.prune(headNumber, headSlot)

proc pruneLoop(pruner: BalPrunerRef) {.async: (raises: [CancelledError]).} =
  info "Starting block access list pruner"

  while true:
    await pruner.pruneCycle()
    await sleepAsync(pruner.loopDelay)

proc init*(
    T: type BalPrunerRef,
    com: CommonRef,
    batchSize = 100'u64,
    loopDelay = chronos.seconds(12),
): T =
  T(
    com: com,
    batchSize: max(1'u64, batchSize),
    loopDelay: loopDelay,
  )

proc start*(pruner: BalPrunerRef) =
  pruner.loopFut = pruner.pruneLoop()

proc stop*(pruner: BalPrunerRef) {.async: (raises: []).} =
  if not pruner.loopFut.isNil:
    await pruner.loopFut.cancelAndWait()
