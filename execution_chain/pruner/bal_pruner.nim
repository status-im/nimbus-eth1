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
  ../block_access_list/bal_utils,
  ../db/core_db,
  ./db_utils,
  ../common

logScope:
  topics = "bal pruner"

type
  BalPrunerRef* = ref object
    ## Deletes the block access lists of blocks which fall outside of the
    ## `BAL_RETENTION_EPOCHS` window, being the weak subjectivity period after
    ## which EIP-7928 no longer requires clients to retain them.
    com: CommonRef
    batchSize: uint64
    loopDelay: chronos.Duration
    loopFut: Future[void].Raising([CancelledError])
    tail*: BlockNumber
      ## The block number up to which block access lists have been deleted

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc findFirstBalBlock(txFrame: CoreDbTxRef, head: BlockNumber): Opt[BlockNumber] =
  ## Binary search for the lowest canonical block which carries a block access
  ## list. Every block from the Amsterdam fork onwards has one and so the search
  ## predicate is monotonic. Blocks which are not stored, such as the ones below
  ## the starting point of a snap synced node, hold no block access list either.
  var
    lo = BlockNumber(0)
    hi = head
    found = Opt.none(BlockNumber)

  while lo <= hi:
    let
      mid = lo + (hi - lo) div 2
      header = txFrame.getBlockHeader(mid).valueOr:
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

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

proc prune*(
    pruner: BalPrunerRef, txFrame: CoreDbTxRef, head: BlockNumber, headSlot: uint64
): Future[uint64] {.async: (raises: [CancelledError]).} =
  ## Deletes the block access lists of the canonical blocks between the pruner
  ## tail and `head` which are no longer within the retention period relative to
  ## `headSlot`. Returns the number of deleted block access lists.
  let kvt = pruner.com.db.kvt

  if pruner.tail == 0:
    pruner.tail = findFirstBalBlock(txFrame, head).valueOr:
      return 0

  var
    currentBlock = pruner.tail
    blocksSinceSave = 0'u64
    pruned = 0'u64

  while currentBlock <= head:
    let
      blockHash = txFrame.getBlockHash(currentBlock).valueOr:
        warn "Failed to get block hash", blkNum = currentBlock, error
        break
      header = txFrame.getBlockHeader(blockHash).valueOr:
        warn "Failed to get header", blkNum = currentBlock, error
        break

    if header.isWithinBalRetentionPeriod(headSlot):
      break

    if header.blockAccessListHash.isSome():
      kvt.deleteBlockAccessListBe(blockHash)
      pruned += 1

    currentBlock += 1
    blocksSinceSave += 1

    if blocksSinceSave >= pruner.batchSize:
      kvt.setBalTailBe(currentBlock)
      pruner.tail = currentBlock
      blocksSinceSave = 0

      await sleepAsync(chronos.milliseconds(100))

  if currentBlock > pruner.tail:
    kvt.setBalTailBe(currentBlock)
    pruner.tail = currentBlock

  if pruned > 0:
    info "Pruned block access lists", pruned, tail = pruner.tail, head

  pruned

proc pruneCycle*(pruner: BalPrunerRef) {.async: (raises: [CancelledError]).} =
  let
    txFrame = pruner.com.db.baseTxFrame()
    head = txFrame.getSavedStateBlockNumber()
    headHeader = txFrame.getBlockHeader(head).valueOr:
      warn "Failed to get head header", blkNum = head, error
      return
    # Blocks before Amsterdam carry no slot number and no block access list
    headSlot = headHeader.slotNumber.valueOr:
      return

  discard await pruner.prune(txFrame, head, headSlot)

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
    batchSize: batchSize,
    loopDelay: loopDelay,
    tail: com.db.kvt.getBalTailBe()
  )

proc start*(pruner: BalPrunerRef) =
  pruner.loopFut = pruner.pruneLoop()

proc stop*(pruner: BalPrunerRef) {.async: (raises: []).} =
  if not pruner.loopFut.isNil:
    await pruner.loopFut.cancelAndWait()
