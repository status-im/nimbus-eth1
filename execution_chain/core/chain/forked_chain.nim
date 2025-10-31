# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables, algorithm, strformat],
  chronicles,
  results,
  chronos,
  ../../common,
  ../../db/[core_db, fcu_db, payload_body_db],
  ../../evm/types,
  ../../evm/state,
  ../validate,
  ../../portal/portal,
  ./forked_chain/[
    chain_desc,
    chain_branch,
    chain_private,
    block_quarantine]

from std/sequtils import mapIt
from web3/engine_api_types import ExecutionPayloadBodyV1

logScope:
  topics = "forked chain"

export
  BlockRef,
  ForkedChainRef,
  common,
  core_db

const
  BaseDistance = 128'u64
  PersistBatchSize = 4'u64
  MaxQueueSize = 128

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func appendBlock(c: ForkedChainRef,
         parent: BlockRef,
         blk: Block,
         blkHash: Hash32,
         txFrame: CoreDbTxRef,
         receipts: sink seq[StoredReceipt]): BlockRef =

  let newBlock = BlockRef(
    blk     : blk,
    txFrame : txFrame,
    receipts: move(receipts),
    hash    : blkHash,
    parent  : parent,
    index   : 0, # Only finalized segment have finalized marker
  )

  c.hashToBlock[blkHash] = newBlock
  c.latest = newBlock

  for i, head in c.heads:
    if head.hash == parent.hash:
      # update existing heads
      c.heads[i] = newBlock
      return newBlock

  # It's a branch
  c.heads.add newBlock
  newBlock

proc fcuSetHead(c: ForkedChainRef,
                txFrame: CoreDbTxRef,
                header: Header,
                hash: Hash32,
                number: uint64) =
  txFrame.setHead(header, hash).expect("setHead OK")
  txFrame.fcuHead(hash, number).expect("fcuHead OK")
  c.fcuHead.number = number
  c.fcuHead.hash = hash

func findHeadPos(c: ForkedChainRef, hash: Hash32): Result[BlockRef, string] =
  ## Find the `BlockRef` that contains the block relative to the
  ## argument `hash`.
  ##
  let b = c.hashToBlock.getOrDefault(hash)
  if b.isNil:
    return err("Cannot find head block: " & hash.short)
  ok(b)

func findFinalizedPos(
    c: ForkedChainRef;
    hash: Hash32;
    head: BlockRef,
      ): Result[BlockRef, string] =
  ## Find header for argument `itHash` on argument `head` ancestor chain.
  ##

  # OK, new finalized stays on the argument head branch.
  # ::
  #         - B3 - B4 - B5 - B6
  #       /              ^    ^
  # A1 - A2 - A3         |    |
  #                      head CCH
  #
  # A1, A2, B3, B4, B5: valid
  # A3, B6: invalid

  # Find `hash` on the ancestor lineage of `head`
  let fin = c.hashToBlock.getOrDefault(hash)

  if fin.isOk:
    if fin.number > head.number:
      return err("Invalid finalizedHash: block is newer than head block")

    # There is no point traversing the DAG if there is only one branch.
    # Just return the node.
    if c.heads.len == 1:
      return ok(fin)

    for it in  ancestors(head):
      if it == fin:
        return ok(fin)

  err("Invalid finalizedHash: block not in argument head ancestor lineage")

func calculateNewBase(
    c: ForkedChainRef;
    finalizedNumber: uint64;
    head: BlockRef;
      ): BlockRef =
  ## It is required that the `finalizedNumber` argument is on the `head` chain, i.e.
  ## it ranges between `c.base.number` and `head.number`.
  ##
  ## The function returns a BlockRef containing a new base position. It is
  ## calculated as follows.
  ##
  ## Starting at the argument `head` searching backwards, the new base
  ## is the position of the block with `finalizedNumber`.
  ##
  ## Before searching backwards, the `finalizedNumber` argument might be adjusted
  ## and made smaller so that a minimum distance to the head on the head arc
  ## applies.
  ##
  # It's important to have base at least `baseDistance` behind head
  # so we can answer state queries about history that deep.
  let target = min(finalizedNumber,
    max(head.number, c.baseDistance) - c.baseDistance)

  # Do not update base.
  if target <= c.base.number:
    return c.base

  # If there is a new base, make sure it moves
  # with large enough step to accomodate for bulk
  # state root verification/bulk persist.
  let distance = target - c.base.number
  if distance < c.persistBatchSize:
    # If the step is not large enough, do nothing.
    return c.base

  # OK, new base stays on the argument head branch.
  # ::
  #                  - B3 - B4 - B5 - B6
  #                /         ^    ^    ^
  #   base - A1 - A2 - A3    |    |    |
  #                          |    head CCH
  #                          |
  #                          target
  #

  # The new base (aka target) falls out of the argument head branch,
  # ending up somewhere on a parent branch.
  # ::
  #                  - B3 - B4 - B5 - B6
  #                /              ^    ^
  #   base - A1 - A2 - A3         |    |
  #           ^                   head CCH
  #           |
  #           target
  #
  # base will not move to A3 onward for this iteration

  for it in ancestors(head):
    if it.number == target:
      return it

  doAssert(false, "Unreachable code, target base should exists")

proc removeBlockFromCache(c: ForkedChainRef, b: BlockRef) =
  c.hashToBlock.del(b.hash)
  for tx in b.blk.transactions:
    c.txRecords.del(computeRlpHash(tx))

  b.blk.reset
  b.receipts.reset
  b.txFrame.dispose()

  # Mark it as removed, don't remove it twice
  b.txFrame = nil
  # Clear parent and let GC claim the memory earlier
  b.parent = nil

proc updateHead(c: ForkedChainRef, head: BlockRef) =
  ## Update head if the new head is different from current head.

  c.fcuSetHead(head.txFrame,
    head.header,
    head.hash,
    head.number)

proc updateFinalized(c: ForkedChainRef, finalized: BlockRef, fcuHead: BlockRef) =
  # Pruning
  # ::
  #                       - B5 - B6 - B7 - B8
  #                    /
  #   A1 - A2 - A3 - [A4] - A5 - A6
  #         \                \
  #           - C3 - C4        - D6 - D7
  #
  # A4 is finalized
  # 'B', 'D', and A5 onward will stay
  # 'C' will be removed

  let txFrame = finalized.txFrame
  txFrame.fcuFinalized(finalized.hash, finalized.number).expect("fcuFinalized OK")

  # There is no point running this expensive algorithm
  # if the chain have no branches, just move it forward.
  if c.heads.len == 1:
    return

  func reachable(head, fin: BlockRef): bool =
    var it = head
    while it.isOk and it.notFinalized:
      it = it.parent
    it == fin

  # Only finalized segment have finalized marker
  for it in loopNotFinalized(finalized):
    it.finalize()

  var
    i = 0
    updateLatest = false

  while i < c.heads.len:
    let head = c.heads[i]

    # Any branches not reachable from finalized
    # should be removed.
    if not reachable(head, finalized):
      for it in loopNotFinalized(head):
        if it.txFrame.isNil:
          # Has been deleted by previous branch
          break
        c.removeBlockFromCache(it)

      if head == c.latest:
        updateLatest = true

      c.heads.del(i)
      # no need to increment i when we delete from c.heads.
      continue

    inc i

  if updateLatest:
    # Previous `latest` is pruned, select a new latest
    # based on longest chain reachable from fcuHead.
    var candidate: BlockRef
    for head in c.heads:
      for it in ancestors(head):
        if it == fcuHead:
          if candidate.isNil:
            candidate = head
          elif head.number > candidate.number:
            candidate = head
          break
        if it.number < fcuHead.number:
          break

    doAssert(candidate.isNil.not)
    c.latest = candidate

proc updateBase(c: ForkedChainRef, base: BlockRef): uint =
  ##
  ##     A1 - A2 - A3          D5 - D6
  ##    /                     /
  ## base - B1 - B2 - [B3] - B4 - B5
  ##         \          \
  ##          C2 - C3    E4 - E5
  ##
  ## where `B1..B5` is the `base` arc and `[B5]` is the `base.head`.
  ##
  ## The `base` will be moved to position `[B3]`.
  ## Both chains `A` and `C` have been removed by `updateFinalized`.
  ## `D` and `E`, and `B4` onward will stay.
  ## B1, B2, B3 will be persisted to DB and removed from FC.

  if base.number == c.base.number:
    # No update, return
    return

  let startTime = Moment.now()

  # State root sanity check is performed to verify, before writing to disk,
  # that optimistically checked blocks indeed end up being stored with a
  # consistent state root.
  # TODO State root checking cost is amortized by performing it only at the
  #      end of a batch of blocks - is there something better the client can
  #      do than shutting down? Either it's a bug or consensus finalized an
  #      invalid block, both of which require attention.
  let frameRoot = base.txFrame.getStateRoot().expect("State root to be readable")
  if frameRoot != base.stateRoot:
    raiseAssert &"""State root sanity check failed, bug?
Expected: {base.stateRoot}, got: {frameRoot}
Either the consensus client gave invalid information about finalized blocks or
something else needs attention! Shutting down to preserve the database - restart
with --debug-eager-state-root."""

  base.txFrame.checkpoint(base.number, skipSnapshot = true)
  c.com.db.persist(base.txFrame)

  # Update baseTxFrame when we about to yield to the event loop
  # and prevent other modules accessing expired baseTxFrame.
  c.baseTxFrame = base.txFrame

  # Cleanup in-memory blocks starting from base backward
  # e.g. B2 backward.
  var count = 0'u

  for it in ancestors(base.parent):
    c.removeBlockFromCache(it)
    inc count

  # Update base branch
  c.base = base
  c.base.parent = nil

  # Base block always have finalized marker
  c.base.finalize()

  if c.dynamicBatchSize:
    # Dynamicly adjust the persistBatchSize based on the recorded run time.
    # The goal here is use the maximum batch size possible without blocking the
    # event loop for too long which could negatively impact the p2p networking.
    # Increasing the batch size can improve performance because the stateroot
    # computation and persist calls are performed less frequently.
    const
      targetTime = 500.milliseconds
      targetTimeDelta = 200.milliseconds
      targetTimeLowerBound = (targetTime - targetTimeDelta).milliseconds
      targetTimeUpperBound = (targetTime + targetTimeDelta).milliseconds
      batchSizeLowerBound = 4
      batchSizeUpperBound = 512

    let
      finishTime = Moment.now()
      runTime = (finishTime - startTime).milliseconds

    if runTime < targetTimeLowerBound and c.persistBatchSize <= batchSizeUpperBound:
      c.persistBatchSize *= 2
      info "Increased persistBatchSize", runTime, targetTime,
        persistBatchSize = c.persistBatchSize
    elif runTime > targetTimeUpperBound and c.persistBatchSize >= batchSizeLowerBound:
      c.persistBatchSize = c.persistBatchSize div 2
      info "Decreased persistBatchSize", runTime, targetTime,
        persistBatchSize = c.persistBatchSize

  count

proc processUpdateBase(c: ForkedChainRef): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  if c.baseQueue.len > 0:
    let base = c.baseQueue.popFirst()
    c.persistedCount += c.updateBase(base)

  const
    minLogInterval = 5

  if c.baseQueue.len == 0:
    let time = EthTime.now()
    if time - c.lastBaseLogTime > minLogInterval:
      # Log only if more than one block persisted
      # This is to avoid log spamming, during normal operation
      # of the client following the chain
      # When multiple blocks are persisted together, it's mainly
      # during `beacon sync` or `nrpc sync`
      if c.persistedCount > 1:
        notice "Finalized blocks persisted",
          nBlocks = c.persistedCount,
          base = c.base.number,
          baseHash = c.base.hash.short,
          pendingFCU = c.pendingFCU.short,
          resolvedFin= c.latestFinalizedBlockNumber
      else:
        debug "Finalized blocks persisted",
          nBlocks = c.persistedCount,
          target = c.base.hash.short,
          base = c.base.number,
          baseHash = c.base.hash.short,
          pendingFCU = c.pendingFCU.short,
          resolvedFin= c.latestFinalizedBlockNumber
      c.lastBaseLogTime = time
      c.persistedCount = 0
    return ok()

  if c.queue.isNil:
    # This recursive mode only used in test env with small set of blocks
    discard await c.processUpdateBase()
  else:
    proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError], raw: true).} =
      c.processUpdateBase()
    await c.queue.addLast(QueueItem(handler: asyncHandler))

  ok()

proc queueUpdateBase(c: ForkedChainRef, base: BlockRef)
     {.async: (raises: [CancelledError]).} =
  let
    prevQueuedBase = if c.baseQueue.len > 0:
                       c.baseQueue.peekLast()
                     else:
                       c.base

  if prevQueuedBase.number >= base.number:
    return

  var
    number = base.number - min(base.number, c.persistBatchSize)
    steps  = newSeqOfCap[BlockRef]((base.number - prevQueuedBase.number) div c.persistBatchSize + 1)
    it = base

  steps.add base

  while it.number > prevQueuedBase.number:
    if it.number == number:
      steps.add it
      number -= min(number, c.persistBatchSize)
    it = it.parent

  for i in countdown(steps.len-1, 0):
    c.baseQueue.addLast(steps[i])

  if c.queue.isNil:
    # This recursive mode only used in test env with small set of blocks
    discard await c.processUpdateBase()
  else:
    proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError], raw: true).} =
      c.processUpdateBase()
    await c.queue.addLast(QueueItem(handler: asyncHandler))

proc validateBlock(c: ForkedChainRef,
          parent: BlockRef,
          blk: Block, finalized: bool): Future[Result[BlockRef, string]]
            {.async: (raises: [CancelledError]).} =
  let
    blkHash = blk.header.computeBlockHash
    existingBlock = c.hashToBlock.getOrDefault(blkHash)

  # Block exists, just return
  if existingBlock.isOk:
    return ok(existingBlock)

  if blkHash == c.pendingFCU:
    # Resolve the hash into latestFinalizedBlockNumber
    c.latestFinalizedBlockNumber = max(blk.header.number,
      c.latestFinalizedBlockNumber)

  let
    # As a memory optimization we move the HashKeys (kMap) stored in the
    # parent txFrame to the new txFrame unless the block number is one
    # greater than a block which is expected to be persisted based on the
    # persistBatchSize
    moveParentHashKeys = c.persistBatchSize > 1 and (blk.header.number mod c.persistBatchSize) != 1
    parentFrame = parent.txFrame
    txFrame = parentFrame.txFrameBegin(moveParentHashKeys)

  # TODO shortLog-equivalent for eth types
  debug "Validating block",
    blkHash, blk = (
      parentHash: blk.header.parentHash,
      coinbase: blk.header.coinbase,
      stateRoot: blk.header.stateRoot,
      transactionsRoot: blk.header.transactionsRoot,
      receiptsRoot: blk.header.receiptsRoot,
      number: blk.header.number,
      gasLimit: blk.header.gasLimit,
      gasUsed: blk.header.gasUsed,
      nonce: blk.header.nonce,
      baseFeePerGas: blk.header.baseFeePerGas,
      withdrawalsRoot: blk.header.withdrawalsRoot,
      blobGasUsed: blk.header.blobGasUsed,
      excessBlobGas: blk.header.excessBlobGas,
      parentBeaconBlockRoot: blk.header.parentBeaconBlockRoot,
      requestsHash: blk.header.requestsHash,
    ),
    parentTxFrame=cast[uint](parentFrame),
    txFrame=cast[uint](txFrame)

  # Checkpoint creates a snapshot of ancestor changes in txFrame - it is an
  # expensive operation, specially when creating a new branch (ie when blk
  # is being applied to a block that is currently not a head).
  # Create the snapshot before processing the block so that any vertexes in snapshots
  # from lower levels than the baseTxFrame are removed from the snapshot before running
  # the stateroot computation.
  parentFrame.checkpoint(parent.blk.header.number, skipSnapshot = false)

  var receipts = c.processBlock(parent, txFrame, blk, blkHash, finalized).valueOr:
    txFrame.dispose()
    return err(error)

  c.writeBaggage(blk, blkHash, txFrame, receipts)

  let newBlock = c.appendBlock(parent, blk, blkHash, txFrame, move(receipts))

  for i, tx in blk.transactions:
    c.txRecords[computeRlpHash(tx)] = (blkHash, uint64(i))

  # Entering base auto forward mode while avoiding forkChoice
  # handled region(head - baseDistance)
  # e.g. live syncing with the tip very far from from our latest head
  let
    offset = c.baseDistance + c.persistBatchSize
    number =
      if offset >= c.latestFinalizedBlockNumber:
        0.uint64
      else:
        c.latestFinalizedBlockNumber - offset
  if c.pendingFCU != zeroHash32 and
     c.base.number < number:
    let
      base = c.calculateNewBase(c.latestFinalizedBlockNumber, c.latest)
      prevBase = c.base.number

    c.updateFinalized(base, base)
    await c.queueUpdateBase(base)

    # If on disk head behind base, move it to base too.
    if c.base.number > prevBase:
      if c.fcuHead.number < c.base.number:
        c.updateHead(c.base)

  ok(newBlock)

template queueOrphan(c: ForkedChainRef, parent: BlockRef, finalized = false): auto =
  if c.queue.isNil:
    # This recursive mode only used in test env with small set of blocks
    discard await c.processOrphan(parent, finalized)
  else:
    proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError], raw: true).} =
      c.processOrphan(parent, finalized)
    await c.queue.addLast(QueueItem(handler: asyncHandler))

proc processOrphan(c: ForkedChainRef, parent: BlockRef, finalized = false): Future[Result[void, string]]
  {.async: (raises: [CancelledError]).} =
  if parent.txFrame.isNil:
    # This can happen if `processUpdateBase` put `updateBase`
    # before `processOrphan` and the `updateBase` remove orphan's parent.txFrame
    # But because of async nature, very hard to replicate or to make a test case.
    # https://github.com/status-im/nimbus-eth1/issues/3526
    return ok()

  let
    orphan = c.quarantine.popOrphan(parent.hash).valueOr:
      # No more orphaned block
      return ok()
    parent = (await c.validateBlock(parent, orphan, finalized)).valueOr:
      # Silent?
      # We don't return error here because the import is still ok()
      # but the quarantined blocks may not linked
      return ok()
  c.queueOrphan(parent, finalized)

proc processQueue(c: ForkedChainRef) {.async: (raises: [CancelledError]).} =
  while true:
    # Cooperative concurrency: one block per loop iteration - because
    # we run both networking and CPU-heavy things like block processing
    # on the same thread, we need to make sure that there is steady progress
    # on the networking side or we get long lockups that lead to timeouts.
    const
      # We cap waiting for an idle slot in case there's a lot of network traffic
      # taking up all CPU - we don't want to _completely_ stop processing blocks
      # in this case - doing so also allows us to benefit from more batching /
      # larger network reads when under load.
      idleTimeout = 10.milliseconds

    discard await idleAsync().withTimeout(idleTimeout)
    let
      item = await c.queue.popFirst()
      res = await item.handler()

    if item.responseFut.isNil:
      continue

    if not item.responseFut.finished:
      item.responseFut.complete res

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc init*(
    T: type ForkedChainRef;
    com: CommonRef;
    baseDistance = BaseDistance;
    persistBatchSize = PersistBatchSize;
    dynamicBatchSize = false;
    eagerStateRoot = false;
    enableQueue = false;
      ): T =
  ## Constructor that uses the current database ledger state for initialising.
  ## This state coincides with the canonical head that would be used for
  ## setting up the descriptor.
  ##
  ## With `ForkedChainRef` based import, the canonical state lives only inside
  ## a level one database transaction. Thus it will readily be available on the
  ## running system with tools such as `getCanonicalHead()`. But it will never
  ## be saved on the database.
  ##
  ## This constructor also works well when resuming import after running
  ## `persistentBlocks()` used for `Era1` or `Era` import.
  ##
  doAssert(persistBatchSize > 0)

  let
    baseTxFrame = com.db.baseTxFrame()
    base = baseTxFrame.getSavedStateBlockNumber
    baseHash = baseTxFrame.getBlockHash(base).expect("baseHash exists")
    baseHeader = baseTxFrame.getBlockHeader(baseHash).expect("base header exists")
    baseBlock = BlockRef(
      blk     : Block(header: baseHeader),
      txFrame : baseTxFrame,
      hash    : baseHash,
      parent  : BlockRef(nil),
    )
    fcuHead = baseTxFrame.fcuHead().valueOr:
      FcuHashAndNumber(hash: baseHash, number: base)
    fcuSafe = baseTxFrame.fcuSafe().valueOr:
      FcuHashAndNumber(hash: baseHash, number: base)
    fc = T(
      com:              com,
      base:             baseBlock,
      latest:           baseBlock,
      heads:            @[baseBlock],
      hashToBlock:      {baseHash: baseBlock}.toTable,
      baseTxFrame:      baseTxFrame,
      baseDistance:     baseDistance,
      persistBatchSize: persistBatchSize,
      dynamicBatchSize: dynamicBatchSize,
      quarantine:       Quarantine.init(),
      fcuHead:          fcuHead,
      fcuSafe:          fcuSafe,
      baseQueue:        initDeque[BlockRef](),
      lastBaseLogTime:  EthTime.now(),
    )

  # updateFinalized will stop ancestor lineage
  # traversal if parent have finalized marker.
  baseBlock.finalize()

  if enableQueue:
    fc.queue = newAsyncQueue[QueueItem](maxsize = MaxQueueSize)
    fc.processingQueueLoop = fc.processQueue()

  fc

proc importBlock*(c: ForkedChainRef, blk: Block):
       Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  ## Try to import block to canonical or side chain.
  ## return error if the block is invalid
  ##
  ## `finalized` should be set to true for blocks that are known to be finalized
  ## already per the latest fork choice update from the consensus client, for
  ## example by following the header chain back from the fcu hash - in such
  ## cases, we perform state root checking in bulk while writing the state to
  ## disk (instead of once for every block).
  template header(): Header =
    blk.header

  let parent = c.hashToBlock.getOrDefault(header.parentHash)
  if parent.isOk:
    # TODO: If engine API keep importing blocks
    # but not finalized it, e.g. current chain length > StagedBlocksThreshold
    # We need to persist some of the in-memory stuff
    # to a "staging area" or disk-backed memory but it must not afect `base`.
    # `base` is the point of no return, we only update it on finality.

    # Setting the finalized flag to true here has the effect of skipping the
    # stateroot check for performance reasons.
    let
      isFinalized = blk.header.number <= c.latestFinalizedBlockNumber
      parent = ?(await c.validateBlock(parent, blk, isFinalized))
    if c.quarantine.hasOrphans():
      c.queueOrphan(parent, isFinalized)

  else:
    # If its parent is an invalid block
    # there is no hope the descendant is valid
    let blockHash = header.computeBlockHash
    debug "Parent block not found",
      blockHash = blockHash.short,
      parentHash = header.parentHash.short

    # Put into quarantine and hope we receive the parent block
    c.quarantine.addOrphan(blockHash, blk)
    return err("Block is not part of valid chain")

  ok()

proc forkChoice*(c: ForkedChainRef,
                 headHash: Hash32,
                 finalizedHash: Hash32,
                 safeHash: Hash32 = zeroHash32):
                    Future[Result[void, string]]
                      {.async: (raises: [CancelledError]).} =

  if finalizedHash != zeroHash32:
    c.pendingFCU = finalizedHash

  if safeHash != zeroHash32:
    let safe = c.hashToBlock.getOrDefault(safeHash)
    if safe.isOk:
      c.fcuSafe.number = safe.number
      c.fcuSafe.hash = safeHash
      ?safe.txFrame.fcuSafe(c.fcuSafe)

  if headHash == c.latest.hash:
    if finalizedHash == zeroHash32:
      # Do nothing if the new head already our current head
      # and there is no request to new finality.
      return ok()

  let
    # Find the unique branch where `headHash` is a member of.
    head = ?c.findHeadPos(headHash)
    # Finalized block must be parent or on the new canonical chain which is
    # represented by `head`.
    finalized = ?c.findFinalizedPos(finalizedHash, head)

  # Head maybe moved backward or moved to other branch.
  c.updateHead(head)
  c.updateFinalized(finalized, head)

  let base = c.calculateNewBase(finalized.number, head)
  if base.number <= c.base.number:
    # The base is not updated, return.
    return ok()

  # At this point head.number >= base.number.
  # At this point finalized.number is <= head.number,
  # and possibly switched to other chain beside the one with head.
  doAssert(finalized.number <= head.number)
  doAssert(base.number <= finalized.number)
  await c.queueUpdateBase(base)

  ok()

proc stopProcessingQueue*(c: ForkedChainRef) {.async: (raises: []).} =
  doAssert(c.processingQueueLoop.isNil.not, "Please set enableQueue=true when constructing FC")
  # noCancel operation prevents race condition between processingQueue
  # and FC.serialize, e.g. the queue is not empty and processingQueue loop still running, and
  # at the same time FC.serialize modify the state, crash can happen.
  await noCancel c.processingQueueLoop.cancelAndWait()

template queueImportBlock*(c: ForkedChainRef, blk: Block): auto =
  proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError], raw: true).} =
    c.importBlock(blk)

  let item = QueueItem(
    responseFut: Future[Result[void, string]].Raising([CancelledError]).init(),
    handler: asyncHandler
  )
  await c.queue.addLast(item)
  item.responseFut

template queueForkChoice*(c: ForkedChainRef,
                 headHash: Hash32,
                 finalizedHash: Hash32,
                 safeHash: Hash32 = zeroHash32): auto =
  proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError], raw: true).} =
    c.forkChoice(headHash, finalizedHash, safeHash)

  let item = QueueItem(
    responseFut: Future[Result[void, string]].Raising([CancelledError]).init(),
    handler: asyncHandler
  )
  await c.queue.addLast(item)
  item.responseFut

func finHash*(c: ForkedChainRef): Hash32 =
  c.pendingFCU

func resolvedFinNumber*(c: ForkedChainRef): uint64 =
  c.latestFinalizedBlockNumber

func haveBlockAndState*(c: ForkedChainRef, blockHash: Hash32): bool =
  ## Blocks still in memory with it's txFrame
  c.hashToBlock.hasKey(blockHash)

func txFrame*(c: ForkedChainRef, blockHash: Hash32): CoreDbTxRef =
  if blockHash == c.base.hash:
    return c.baseTxFrame

  c.hashToBlock.withValue(blockHash, loc) do:
    return loc[].txFrame

  c.baseTxFrame

func baseTxFrame*(c: ForkedChainRef): CoreDbTxRef =
  c.baseTxFrame

func txFrame*(c: ForkedChainRef, header: Header): CoreDbTxRef =
  c.txFrame(header.computeBlockHash())

func latestTxFrame*(c: ForkedChainRef): CoreDbTxRef =
  c.latest.txFrame

func com*(c: ForkedChainRef): CommonRef =
  c.com

func db*(c: ForkedChainRef): CoreDbRef =
  c.com.db

func latestHeader*(c: ForkedChainRef): Header =
  c.latest.header

func latestNumber*(c: ForkedChainRef): BlockNumber =
  c.latest.number

func latestHash*(c: ForkedChainRef): Hash32 =
  c.latest.hash

func baseNumber*(c: ForkedChainRef): BlockNumber =
  c.base.number

func baseHash*(c: ForkedChainRef): Hash32 =
  c.base.hash

func txRecords*(c: ForkedChainRef, txHash: Hash32): (Hash32, uint64) =
  c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))

func isInMemory*(c: ForkedChainRef, blockHash: Hash32): bool =
  c.hashToBlock.hasKey(blockHash)

func isHistoryExpiryActive*(c: ForkedChainRef): bool =
  not c.portal.isNil

func isPortalActive(c: ForkedChainRef): bool =
  (not c.portal.isNil) and c.portal.portalEnabled

func memoryTransaction*(c: ForkedChainRef, txHash: Hash32): Opt[(Transaction, BlockNumber)] =
  let (blockHash, index) = c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))
  let b = c.hashToBlock.getOrDefault(blockHash)
  if b.isOk:
    return Opt.some( (b.blk.transactions[index], b.number) )
  return Opt.none((Transaction, BlockNumber))

func memoryTxHashesForBlock*(c: ForkedChainRef, blockHash: Hash32): Opt[seq[Hash32]] =
  var cachedTxHashes = newSeq[(Hash32, uint64)]()
  for txHash, (blkHash, txIdx) in c.txRecords.pairs:
    if blkHash == blockHash:
      cachedTxHashes.add((txHash, txIdx))

  if cachedTxHashes.len <= 0:
    return Opt.none(seq[Hash32])

  cachedTxHashes.sort(proc(a, b: (Hash32, uint64)): int =
      cmp(a[1], b[1])
    )
  Opt.some(cachedTxHashes.mapIt(it[0]))

proc latestBlock*(c: ForkedChainRef): Block =
  if c.latest.number == c.base.number:
    # It's a base block
    return c.baseTxFrame.getEthBlock(c.latest.hash).expect("baseBlock exists")
  c.latest.blk

proc headerByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Header, string] =
  if number > c.latest.number:
    return err("Requested block number not exists: " & $number)

  if number < c.base.number:
    return c.baseTxFrame.getBlockHeader(number)

  for it in ancestors(c.latest):
    if number == it.number:
      return ok(it.header)

  err("Block not found, number = " & $number)

func finalizedHeader*(c: ForkedChainRef): Header =
  c.hashToBlock.withValue(c.pendingFCU, loc):
    return loc[].header

  c.base.header

func safeHeader*(c: ForkedChainRef): Header =
  c.hashToBlock.withValue(c.fcuSafe.hash, loc):
    return loc[].header

  c.base.header

func finalizedBlock*(c: ForkedChainRef): Block =
  c.hashToBlock.withValue(c.pendingFCU, loc):
    return loc[].blk

  c.base.blk

func safeBlock*(c: ForkedChainRef): Block =
  c.hashToBlock.withValue(c.fcuSafe.hash, loc):
    return loc[].blk

  c.base.blk

proc headerByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Header, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].header)

  c.baseTxFrame.getBlockHeader(blockHash)

proc txDetailsByTxHash*(c: ForkedChainRef, txHash: Hash32): Result[(Hash32, uint64), string] =
  if c.txRecords.hasKey(txHash):
    let (blockHash, txid) = c.txRecords(txHash)
    return ok((blockHash, txid))

  let
    txDetails = ?c.baseTxFrame.getTransactionKey(txHash)
    header = ?c.headerByNumber(txDetails.blockNumber)
    blockHash = header.computeBlockHash
  return ok((blockHash, txDetails.index))

# TODO: Doesn't fetch data from portal
# Aristo returns empty txs for both non-existent blocks and existing blocks with no txs [ Solve ? ]
proc blockBodyByHash*(c: ForkedChainRef, blockHash: Hash32): Result[BlockBody, string] =
  c.hashToBlock.withValue(blockHash, loc):
    let blk = loc[].blk
    return ok(BlockBody(
      transactions: blk.transactions,
      uncles: blk.uncles,
      withdrawals: blk.withdrawals,
    ))
  c.baseTxFrame.getBlockBody(blockHash)

proc blockByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Block, string] =
  # used by getPayloadBodiesByHash
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-3
  # 4. Client software MAY NOT respond to requests for finalized blocks by hash.
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].blk)
  var header = ?c.baseTxFrame.getBlockHeader(blockHash)
  var blockBody = c.baseTxFrame.getBlockBody(header).valueOr:
    # Serve portal data if block not found in db
    if c.isPortalActive:
      var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
      return ok(EthBlock.init(move(header), move(blockBodyPortal)))
    else:
      return err(error)

  ok(EthBlock.init(move(header), move(blockBody)))

proc payloadBodyV1ByHash*(c: ForkedChainRef, blockHash: Hash32): Result[ExecutionPayloadBodyV1, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(toPayloadBody(loc[].blk))

  var header = ?c.baseTxFrame.getBlockHeader(blockHash)
  var blk = c.baseTxFrame.getExecutionPayloadBodyV1(header)

  if blk.isErr:
    # Serve portal data if block not found in db
    if c.isPortalActive:
      var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
      # Same as above
      return ok(toPayloadBody(EthBlock.init(move(header), move(blockBodyPortal))))

  move(blk)

proc payloadBodyV1ByNumber*(c: ForkedChainRef, number: BlockNumber): Result[ExecutionPayloadBodyV1, string] =
  if number > c.latest.number:
    return err("Requested block number not exists: " & $number)

  if number <= c.base.number:
    var header = ?c.baseTxFrame.getBlockHeader(number)
    let blk = c.baseTxFrame.getExecutionPayloadBodyV1(header)

    if blk.isErr:
      # Serve portal data if block not found in db
      if c.isPortalActive:
        var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
        # same as above
        return ok(toPayloadBody(EthBlock.init(move(header), move(blockBodyPortal))))

    return blk

  for it in ancestors(c.latest):
    if number >= it.number:
      return ok(toPayloadBody(it.blk))

  err("Block not found, number = " & $number)

proc blockByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Block, string] =
  if number > c.latest.number:
    return err("Requested block number not exists: " & $number)

  if number <= c.base.number:
    var header = ?c.baseTxFrame.getBlockHeader(number)
    var blockBody = c.baseTxFrame.getBlockBody(header).valueOr:
      # Serve portal data if block not found in db
      if c.isPortalActive:
        var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
        return ok(EthBlock.init(move(header), move(blockBodyPortal)))
      else:
        return err(error)

    return ok(EthBlock.init(move(header), move(blockBody)))

  for it in ancestors(c.latest):
    if number >= it.number:
      return ok(it.blk)

  err("Block not found, number = " & $number)

proc blockHeader*(c: ForkedChainRef, blk: BlockHashOrNumber): Result[Header, string] =
  if blk.isHash:
    return c.headerByHash(blk.hash)
  c.headerByNumber(blk.number)

proc receiptsByBlockHash*(c: ForkedChainRef, blockHash: Hash32): Result[seq[StoredReceipt], string] =
  if blockHash != c.base.hash:
    c.hashToBlock.withValue(blockHash, loc):
      return ok(loc[].receipts)

  let header = c.baseTxFrame.getBlockHeader(blockHash).valueOr:
    return err("Block header not found")

  c.baseTxFrame.getReceipts(header.receiptsRoot)

func payloadBodyV1InMemory*(c: ForkedChainRef,
                            first: BlockNumber,
                            last: BlockNumber,
                            list: var seq[Opt[ExecutionPayloadBodyV1]]) =
  var
    blocks = newSeqOfCap[BlockRef](last-first+1)

  for it in ancestors(c.latest):
    if it.number >= first and it.number <= last:
      blocks.add(it)

  for i in countdown(blocks.len-1, 0):
    let y = blocks[i]
    list.add Opt.some(toPayloadBody(y.blk))

func equalOrAncestorOf*(c: ForkedChainRef, blockHash: Hash32, headHash: Hash32): bool =
  if blockHash == headHash:
    return true

  let head = c.hashToBlock.getOrDefault(headHash)
  for it in ancestors(head):
    if it.hash == blockHash:
      return true

  false

proc isCanonicalAncestor*(c: ForkedChainRef,
                    blockNumber: BlockNumber,
                    blockHash: Hash32): bool =
  if blockNumber >= c.latest.number:
    return false

  if blockHash == c.latest.hash:
    return false

  if c.base.number < c.latest.number:
    # The current canonical chain in memory is headed by
    # latest.header
    for it in ancestors(c.latest):
      if it.hash == blockHash and it.number == blockNumber:
        return true

  # canonical chain in database should have a marker
  # and the marker is block number
  let canonHash = c.baseTxFrame.getBlockHash(blockNumber).valueOr:
    return false
  canonHash == blockHash

iterator txHashInRange*(c: ForkedChainRef, fromHash: Hash32, toHash: Hash32): Hash32 =
  ## toHash should be ancestor of fromHash
  ## exclude base from iteration, new block produced by txpool
  ## should not reach base
  let head = c.hashToBlock.getOrDefault(fromHash)
  for it in ancestors(head):
    if toHash == it.hash:
      break
    for tx in it.blk.transactions:
      let txHash = computeRlpHash(tx)
      yield txHash
