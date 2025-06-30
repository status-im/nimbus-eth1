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
  std/[tables, algorithm],
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
  BlockDesc,
  ForkedChainRef,
  common,
  core_db

const
  BaseDistance = 128'u64
  PersistBatchSize = 32'u64
  MaxQueueSize = 9

# ------------------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------------------

proc updateBase(c: ForkedChainRef, newBase: BlockPos):
  Future[void] {.async: (raises: [CancelledError]), gcsafe.}
func calculateNewBase(c: ForkedChainRef;
       finalizedNumber: uint64; head: BlockPos): BlockPos {.gcsafe.}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func updateBranch(c: ForkedChainRef,
         parent: BlockPos,
         blk: Block,
         blkHash: Hash32,
         txFrame: CoreDbTxRef,
         receipts: sink seq[StoredReceipt]) =
  if parent.isHead:
    parent.appendBlock(blk, blkHash, txFrame, move(receipts))
    c.hashToBlock[blkHash] = parent.lastBlockPos
    c.activeBranch = parent.branch
    return

  let newBranch = branch(parent.branch, blk, blkHash, txFrame, move(receipts))
  c.hashToBlock[blkHash] = newBranch.lastBlockPos
  c.branches.add(newBranch)
  c.activeBranch = newBranch

proc fcuSetHead(c: ForkedChainRef,
                txFrame: CoreDbTxRef,
                header: Header,
                hash: Hash32,
                number: uint64) =
  txFrame.setHead(header, hash).expect("setHead OK")
  txFrame.fcuHead(hash, number).expect("fcuHead OK")
  c.fcuHead.number = number
  c.fcuHead.hash = hash

proc validateBlock(c: ForkedChainRef,
          parent: BlockPos,
          blk: Block, finalized: bool): Future[Result[Hash32, string]]
            {.async: (raises: [CancelledError]).} =
  let blkHash = blk.header.computeBlockHash

  if c.hashToBlock.hasKey(blkHash):
    # Block exists, just return
    return ok(blkHash)

  if blkHash == c.pendingFCU:
    # Resolve the hash into latestFinalizedBlockNumber
    c.latestFinalizedBlockNumber = max(blk.header.number,
      c.latestFinalizedBlockNumber)

  let
    parentFrame = parent.txFrame
    txFrame = parentFrame.txFrameBegin

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
    )

  var receipts = c.processBlock(parent.header, txFrame, blk, blkHash, finalized).valueOr:
    txFrame.dispose()
    return err(error)

  c.writeBaggage(blk, blkHash, txFrame, receipts)

  c.updateSnapshot(blk, txFrame)

  c.updateBranch(parent, blk, blkHash, txFrame, move(receipts))

  for i, tx in blk.transactions:
    c.txRecords[computeRlpHash(tx)] = (blkHash, uint64(i))

  # Entering base auto forward mode while avoiding forkChoice
  # handled region(head - baseDistance)
  # e.g. live syncing with the tip very far from from our latest head
  if c.pendingFCU != zeroHash32 and
     c.baseBranch.tailNumber < c.latestFinalizedBlockNumber - c.baseDistance - c.persistBatchSize:
    let
      head = c.activeBranch.lastBlockPos
      newBaseCandidate = c.calculateNewBase(c.latestFinalizedBlockNumber, head)
      prevBaseNumber = c.baseBranch.tailNumber

    await c.updateBase(newBaseCandidate)

    # If on disk head behind base, move it to base too.
    let newBaseNumber = c.baseBranch.tailNumber
    if newBaseNumber > prevBaseNumber:
      if c.fcuHead.number < newBaseNumber:
        let head = c.baseBranch.firstBlockPos
        c.fcuSetHead(head.txFrame,
          head.branch.tailHeader,
          head.branch.tailHash,
          head.branch.tailNumber)

  ok(blkHash)

func findHeadPos(c: ForkedChainRef, hash: Hash32): Result[BlockPos, string] =
  ## Find the `BlockPos` that contains the block relative to the
  ## argument `hash`.
  ##
  c.hashToBlock.withValue(hash, val) do:
    return ok(val[])
  do:
    return err("Block hash is not part of any active chain")

func findFinalizedPos(
    c: ForkedChainRef;
    itHash: Hash32;
    head: BlockPos,
      ): Result[BlockPos, string] =
  ## Find header for argument `itHash` on argument `head` ancestor chain.
  ##

  # OK, new base stays on the argument head branch.
  # ::
  #         - B3 - B4 - B5 - B6
  #       /              ^    ^
  # A1 - A2 - A3         |    |
  #                      head CCH
  #
  # A1, A2, B3, B4, B5: valid
  # A3, B6: invalid

  # Find `itHash` on the ancestor lineage of `head`
  c.hashToBlock.withValue(itHash, loc):
    if loc[].number > head.number:
      return err("Invalid finalizedHash: block is newer than head block")

    var
      branch = head.branch
      prevBranch = BranchRef(nil)

    while not branch.isNil:
      if branch == loc[].branch:
        if prevBranch.isNil.not and
           loc[].number >= prevBranch.tailNumber:
          break # invalid
        return ok(loc[])

      prevBranch = branch
      branch = branch.parent

  err("Invalid finalizedHash: block not in argument head ancestor lineage")

func calculateNewBase(
    c: ForkedChainRef;
    finalizedNumber: uint64;
    head: BlockPos;
      ): BlockPos =
  ## It is required that the `finalizedNumber` argument is on the `head` chain, i.e.
  ## it ranges beween `c.baseBranch.tailNumber` and
  ## `head.branch.headNumber`.
  ##
  ## The function returns a BlockPos containing a new base position. It is
  ## calculated as follows.
  ##
  ## Starting at the argument `head.branch` searching backwards, the new base
  ## is the position of the block with `finalizedNumber`.
  ##
  ## Before searching backwards, the `finalizedNumber` argument might be adjusted
  ## and made smaller so that a minimum distance to the head on the cursor arc
  ## applies.
  ##
  # It's important to have base at least `baseDistance` behind head
  # so we can answer state queries about history that deep.
  let target = min(finalizedNumber,
    max(head.number, c.baseDistance) - c.baseDistance)

  # Do not update base.
  if target <= c.baseBranch.tailNumber:
    return BlockPos(branch: c.baseBranch)

  # If there is a new base, make sure it moves
  # with large enough step to accomodate for bulk
  # state root verification/bulk persist.
  let distance = target - c.baseBranch.tailNumber
  if distance < c.persistBatchSize:
    # If the step is not large enough, do nothing.
    return BlockPos(branch: c.baseBranch)

  if target >= head.branch.tailNumber:
    # OK, new base stays on the argument head branch.
    # ::
    #                  - B3 - B4 - B5 - B6
    #                /         ^    ^    ^
    #   base - A1 - A2 - A3    |    |    |
    #                          |    head CCH
    #                          |
    #                          target
    #
    return BlockPos(
      branch: head.branch,
      index : int(target - head.branch.tailNumber)
    )

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
  var branch = head.branch.parent
  while not branch.isNil:
    if target >= branch.tailNumber:
      return BlockPos(
        branch: branch,
        index : int(target - branch.tailNumber)
      )
    branch = branch.parent

  doAssert(false, "Unreachable code, finalized block outside canonical chain")

proc removeBlockFromCache(c: ForkedChainRef, bd: BlockDesc) =
  c.hashToBlock.del(bd.hash)
  for tx in bd.blk.transactions:
    c.txRecords.del(computeRlpHash(tx))

  for v in c.lastSnapshots.mitems():
    if v == bd.txFrame:
      v = nil

  bd.txFrame.dispose()

proc updateHead(c: ForkedChainRef, head: BlockPos) =
  ## Update head if the new head is different from current head.
  ## All branches with block number greater than head will be removed too.

  c.activeBranch = head.branch

  # Pruning if necessary
  # ::
  #                       - B5 - B6 - B7 - B8
  #                    /
  #   A1 - A2 - A3 - [A4] - A5 - A6
  #         \                \
  #           - C3 - C4        - D6 - D7
  #
  # A4 is head
  # 'D' and 'A5' onward will be removed
  # 'C' and 'B' will stay

  let headNumber = head.number
  var i = 0
  while i < c.branches.len:
    let branch = c.branches[i]

    # Any branches with block number greater than head+1 should be removed.
    if branch.tailNumber > headNumber + 1:
      for i in countdown(branch.blocks.len-1, 0):
        c.removeBlockFromCache(branch.blocks[i])
      c.branches.del(i)
      # no need to increment i when we delete from c.branches.
      continue

    inc i

  # Maybe the current active chain is longer than canonical chain,
  # trim the branch.
  for i in countdown(head.branch.len-1, head.index+1):
    c.removeBlockFromCache(head.branch.blocks[i])

  head.branch.blocks.setLen(head.index+1)
  c.fcuSetHead(head.txFrame,
    head.branch.headHeader,
    head.branch.headHash,
    head.branch.headNumber)

proc updateFinalized(c: ForkedChainRef, finalized: BlockPos) =
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

  func sameLineage(brc: BranchRef, line: BranchRef): bool =
    var branch = line
    while not branch.isNil:
      if branch == brc:
        return true
      branch = branch.parent

  let finalizedNumber = finalized.number
  var i = 0
  while i < c.branches.len:
    let branch = c.branches[i]

    # Any branches with tail block number less or equal
    # than finalized should be removed.
    if not branch.sameLineage(finalized.branch) and branch.tailNumber <= finalizedNumber:
      for i in countdown(branch.blocks.len-1, 0):
        c.removeBlockFromCache(branch.blocks[i])
      c.branches.del(i)
      # no need to increment i when we delete from c.branches.
      continue

    inc i

  let txFrame = finalized.txFrame
  txFrame.fcuFinalized(finalized.hash, finalized.number).expect("fcuFinalized OK")

proc updateBase(c: ForkedChainRef, newBase: BlockPos):
  Future[void] {.async: (raises: [CancelledError]), gcsafe.} =
  ##
  ##     A1 - A2 - A3          D5 - D6
  ##    /                     /
  ## base - B1 - B2 - [B3] - B4 - B5
  ##         \          \
  ##          C2 - C3    E4 - E5
  ##
  ## where `B1..B5` is the `newBase.branch` arc and `[B5]` is the `newBase.headNumber`.
  ##
  ## The `base` will be moved to position `[B3]`.
  ## Both chains `A` and `C` have be removed by updateFinalized.
  ## `D` and `E`, and `B4` onward will stay.
  ## B1, B2, B3 will be persisted to DB and removed from FC.

  # Cleanup in-memory blocks starting from newBase backward
  # e.g. B3 backward. Switch to parent branch if needed.

  template disposeBlocks(number, branch) =
    let tailNumber = branch.tailNumber
    while number >= tailNumber:
      c.removeBlockFromCache(branch.blocks[number - tailNumber])
      inc count

      if number == 0:
        # Don't go below genesis
        break
      dec number

  let oldBase = c.baseBranch.tailNumber
  if newBase.number == oldBase:
    # No update, return
    return

  var
    branch = newBase.branch
    number = newBase.number - 1
    count  = 0

  let
    # Cache to prevent crash after we shift
    # the blocks
    newBaseHash = newBase.hash
    nextIndex   = int(newBase.number - branch.tailNumber)

  # Persist the new base block - this replaces the base tx in coredb!
  for x in newBase.everyNthBlock(4):
    const
      # We cap waiting for an idle slot in case there's a lot of network traffic
      # taking up all CPU - we don't want to _completely_ stop processing blocks
      # in this case - doing so also allows us to benefit from more batching /
      # larger network reads when under load.
      idleTimeout = 10.milliseconds

    discard await idleAsync().withTimeout(idleTimeout)
    c.com.db.persist(x.txFrame, Opt.some(x.stateRoot))

    # Update baseTxFrame when we about to yield to the event loop
    # and prevent other modules accessing expired baseTxFrame.
    c.baseTxFrame = x.txFrame

  disposeBlocks(number, branch)

  # Update base if it indeed changed
  if nextIndex > 0:
    # Only remove blocks with number lower than newBase.number
    var blocks = newSeqOfCap[BlockDesc](branch.len-nextIndex)
    for i in nextIndex..<branch.len:
      blocks.add branch.blocks[i]

    # Update hashToBlock index
    for i in 0..<blocks.len:
      c.hashToBlock[blocks[i].hash] = BlockPos(
        branch: branch,
        index : i
      )
    branch.blocks = move(blocks)

  # Older branches will gone
  branch = branch.parent
  while not branch.isNil:
    var delNumber = branch.headNumber
    disposeBlocks(delNumber, branch)

    for i, brc in c.branches:
      if brc == branch:
        c.branches.del(i)
        break

    branch = branch.parent

  # Update base branch
  c.baseBranch = newBase.branch
  c.baseBranch.parent = nil

  # Log only if more than one block persisted
  # This is to avoid log spamming, during normal operation
  # of the client following the chain
  # When multiple blocks are persisted together, it's mainly
  # during `beacon sync` or `nrpc sync`
  if count > 1:
    notice "Finalized blocks persisted",
      nBlocks = count,
      base = c.baseBranch.tailNumber,
      baseHash = c.baseBranch.tailHash.short,
      pendingFCU = c.pendingFCU.short,
      resolvedFin= c.latestFinalizedBlockNumber
  else:
    debug "Finalized blocks persisted",
      nBlocks = count,
      target = newBaseHash.short,
      base = c.baseBranch.tailNumber,
      baseHash = c.baseBranch.tailHash.short,
      pendingFCU = c.pendingFCU.short,
      resolvedFin= c.latestFinalizedBlockNumber

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
  let
    baseTxFrame = com.db.baseTxFrame()
    base = baseTxFrame.getSavedStateBlockNumber
    baseHash = baseTxFrame.getBlockHash(base).expect("baseHash exists")
    baseHeader = baseTxFrame.getBlockHeader(baseHash).expect("base header exists")
    baseBranch = branch(baseHeader, baseHash, baseTxFrame)
    fcuHead = baseTxFrame.fcuHead().valueOr:
      FcuHashAndNumber(hash: baseHash, number: baseHeader.number)
    fcuSafe = baseTxFrame.fcuSafe().valueOr:
      FcuHashAndNumber(hash: baseHash, number: baseHeader.number)
    fc = T(com:             com,
      baseBranch:      baseBranch,
      activeBranch:    baseBranch,
      branches:        @[baseBranch],
      hashToBlock:     {baseHash: baseBranch.lastBlockPos}.toTable,
      baseTxFrame:     baseTxFrame,
      baseDistance:    baseDistance,
      persistBatchSize:persistBatchSize,
      quarantine:      Quarantine.init(),
      fcuHead:         fcuHead,
      fcuSafe:         fcuSafe,
    )

  if enableQueue:
    fc.queue = newAsyncQueue[QueueItem](maxsize = MaxQueueSize)
    fc.processingQueueLoop = fc.processQueue()

  fc

proc importBlock*(c: ForkedChainRef, blk: Block, finalized = false):
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

  c.hashToBlock.withValue(header.parentHash, parentPos) do:
    # TODO: If engine API keep importing blocks
    # but not finalized it, e.g. current chain length > StagedBlocksThreshold
    # We need to persist some of the in-memory stuff
    # to a "staging area" or disk-backed memory but it must not afect `base`.
    # `base` is the point of no return, we only update it on finality.

    var parentHash = ?(await c.validateBlock(parentPos[], blk, finalized))

    while c.quarantine.hasOrphans():
      const
        # We cap waiting for an idle slot in case there's a lot of network traffic
        # taking up all CPU - we don't want to _completely_ stop processing blocks
        # in this case - doing so also allows us to benefit from more batching /
        # larger network reads when under load.
        idleTimeout = 10.milliseconds

      discard await idleAsync().withTimeout(idleTimeout)

      let orphan = c.quarantine.popOrphan(parentHash).valueOr:
        break

      c.hashToBlock.withValue(parentHash, parentCandidatePos) do:
        parentHash = (await c.validateBlock(parentCandidatePos[], orphan, finalized)).valueOr:
          # Silent?
          # We don't return error here because the import is still ok()
          # but the quarantined blocks may not linked
          break
      do:
        break
  do:
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
    c.hashToBlock.withValue(safeHash, loc):
      let number = loc[].number
      c.fcuSafe.number = number
      c.fcuSafe.hash = safeHash
      ?loc[].txFrame.fcuSafe(c.fcuSafe)

  if headHash == c.activeBranch.headHash:
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

  if finalizedHash == zeroHash32:
    # skip updateBase and updateFinalized if finalizedHash is zero.
    return ok()

  c.updateFinalized(finalized)

  let
    finalizedNumber = finalized.number
    newBase = c.calculateNewBase(finalizedNumber, head)

  if newBase.hash == c.baseBranch.tailHash:
    # The base is not updated, return.
    return ok()

  # Cache the base block number, updateBase might
  # alter the BlockPos.index
  let newBaseNumber = newBase.number

  # At this point head.number >= base.number.
  # At this point finalized.number is <= head.number,
  # and possibly switched to other chain beside the one with head.
  doAssert(finalizedNumber <= head.number)
  doAssert(newBaseNumber <= finalizedNumber)
  await c.updateBase(newBase)

  ok()

proc stopProcessingQueue*(c: ForkedChainRef) {.async: (raises: [CancelledError]).} =
  doAssert(c.processingQueueLoop.isNil.not, "Please set enableQueue=true when constructing FC")
  await c.processingQueueLoop.cancelAndWait()

template queueImportBlock*(c: ForkedChainRef, blk: Block, finalized = false): auto =
  proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
    await c.importBlock(blk, finalized)

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
  proc asyncHandler(): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
    await c.forkChoice(headHash, finalizedHash, safeHash)

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
  if blockHash == c.baseBranch.tailHash:
    return c.baseTxFrame

  c.hashToBlock.withValue(blockHash, loc) do:
    return loc[].txFrame

  c.baseTxFrame

func baseTxFrame*(c: ForkedChainRef): CoreDbTxRef =
  c.baseTxFrame

func txFrame*(c: ForkedChainRef, header: Header): CoreDbTxRef =
  c.txFrame(header.computeBlockHash())

func latestTxFrame*(c: ForkedChainRef): CoreDbTxRef =
  c.activeBranch.headTxFrame

func com*(c: ForkedChainRef): CommonRef =
  c.com

func db*(c: ForkedChainRef): CoreDbRef =
  c.com.db

func latestHeader*(c: ForkedChainRef): Header =
  c.activeBranch.headHeader

func latestNumber*(c: ForkedChainRef): BlockNumber =
  c.activeBranch.headNumber

func latestHash*(c: ForkedChainRef): Hash32 =
  c.activeBranch.headHash

func baseNumber*(c: ForkedChainRef): BlockNumber =
  c.baseBranch.tailNumber

func baseHash*(c: ForkedChainRef): Hash32 =
  c.baseBranch.tailHash

func txRecords*(c: ForkedChainRef, txHash: Hash32): (Hash32, uint64) =
  c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))

func isInMemory*(c: ForkedChainRef, blockHash: Hash32): bool =
  c.hashToBlock.hasKey(blockHash)

func isHistoryExpiryActive*(c: ForkedChainRef): bool =
  not c.portal.isNil

func isPortalActive(c: ForkedChainRef): bool =
  (not c.portal.isNil) and c.portal.portalEnabled

func memoryBlock*(c: ForkedChainRef, blockHash: Hash32): BlockDesc =
  c.hashToBlock.withValue(blockHash, loc):
    return loc.branch.blocks[loc.index]
  # Return default(BlockDesc)

func memoryTransaction*(c: ForkedChainRef, txHash: Hash32): Opt[(Transaction, BlockNumber)] =
  let (blockHash, index) = c.txRecords.getOrDefault(txHash, (Hash32.default, 0'u64))
  c.hashToBlock.withValue(blockHash, loc) do:
    return Opt.some( (loc[].tx(index), loc[].number) )
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
  if c.activeBranch.headNumber == c.baseBranch.tailNumber:
    # It's a base block
    return c.baseTxFrame.getEthBlock(c.activeBranch.headHash).expect("cursorBlock exists")
  c.activeBranch.blocks[^1].blk

proc headerByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Header, string] =
  if number > c.activeBranch.headNumber:
    return err("Requested block number not exists: " & $number)

  if number < c.baseBranch.tailNumber:
    let hdr = c.baseTxFrame.getBlockHeader(number).valueOr:
      if c.isPortalActive:
        return c.portal.getHeaderByNumber(number)
      else:
        return err("Portal inactive, block not found, number = " & $number)
    return ok(hdr)

  var branch = c.activeBranch
  while not branch.isNil:
    if number >= branch.tailNumber:
      return ok(branch.blocks[number - branch.tailNumber].blk.header)
    branch = branch.parent

  err("Block not found, number = " & $number)

func finalizedHeader*(c: ForkedChainRef): Header =
  c.hashToBlock.withValue(c.pendingFCU, loc):
    return loc[].header

  c.baseBranch.tailHeader

func safeHeader*(c: ForkedChainRef): Header =
  c.hashToBlock.withValue(c.fcuSafe.hash, loc):
    return loc[].header

  c.baseBranch.tailHeader

func finalizedBlock*(c: ForkedChainRef): Block =
  c.hashToBlock.withValue(c.pendingFCU, loc):
    return loc[].blk

  c.baseBranch.tailBlock

func safeBlock*(c: ForkedChainRef): Block =
  c.hashToBlock.withValue(c.fcuSafe.hash, loc):
    return loc[].blk

  c.baseBranch.tailBlock

proc headerByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Header, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].header)
  let hdr = c.baseTxFrame.getBlockHeader(blockHash).valueOr:
    if c.isPortalActive:
      return c.portal.getHeaderByHash(blockHash)
    else:
      return err("Block header not found")
  ok(hdr)

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
  let blk = c.baseTxFrame.getEthBlock(blockHash)
  # Serves portal data if block not found in db
  if blk.isErr or (blk.get.transactions.len == 0 and blk.get.header.transactionsRoot != zeroHash32):
    if c.isPortalActive:
      return c.portal.getBlockByHash(blockHash)
  blk

proc payloadBodyV1ByHash*(c: ForkedChainRef, blockHash: Hash32): Result[ExecutionPayloadBodyV1, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(toPayloadBody(loc[].blk))

  let header = ?c.baseTxFrame.getBlockHeader(blockHash)
  var blk = c.baseTxFrame.getExecutionPayloadBodyV1(header)

  # Serves portal data if block not found in db
  if blk.isErr or (blk.get.transactions.len == 0 and header.transactionsRoot != zeroHash32):
    if c.isPortalActive:
      let blk = ?c.portal.getBlockByHash(blockHash)
      return ok(toPayloadBody(blk))

  move(blk)

proc payloadBodyV1ByNumber*(c: ForkedChainRef, number: BlockNumber): Result[ExecutionPayloadBodyV1, string] =
  if number > c.activeBranch.headNumber:
    return err("Requested block number not exists: " & $number)

  if number <= c.baseBranch.tailNumber:
    let
      header = ?c.baseTxFrame.getBlockHeader(number)
      blk = c.baseTxFrame.getExecutionPayloadBodyV1(header)

    # Txs not there in db - Happens during era1/era import, when we don't store txs and receipts
    if blk.isErr or (blk.get.transactions.len == 0 and header.transactionsRoot != emptyRoot):
      # Serves portal data if block not found in database
      if c.isPortalActive:
        let blk = ?c.portal.getBlockByNumber(number)
        return ok(toPayloadBody(blk))

    return blk

  var branch = c.activeBranch
  while not branch.isNil:
    if number >= branch.tailNumber:
      return ok(toPayloadBody(branch.blocks[number - branch.tailNumber].blk))
    branch = branch.parent

  err("Block not found, number = " & $number)

proc blockByNumber*(c: ForkedChainRef, number: BlockNumber): Result[Block, string] =
  if number > c.activeBranch.headNumber:
    return err("Requested block number not exists: " & $number)

  if number <= c.baseBranch.tailNumber:
    let blk = c.baseTxFrame.getEthBlock(number)
    # Txs not there in db - Happens during era1/era import, when we don't store txs and receipts
    if blk.isErr or (blk.get.transactions.len == 0 and blk.get.header.transactionsRoot != emptyRoot):
      # Serves portal data if block not found in database
      if c.isPortalActive:
        return c.portal.getBlockByNumber(number)
    else:
      return blk

  var branch = c.activeBranch
  while not branch.isNil:
    if number >= branch.tailNumber:
      return ok(branch.blocks[number - branch.tailNumber].blk)
    branch = branch.parent

  err("Block not found, number = " & $number)

proc blockHeader*(c: ForkedChainRef, blk: BlockHashOrNumber): Result[Header, string] =
  if blk.isHash:
    return c.headerByHash(blk.hash)
  c.headerByNumber(blk.number)

proc receiptsByBlockHash*(c: ForkedChainRef, blockHash: Hash32): Result[seq[StoredReceipt], string] =
  if blockHash != c.baseBranch.tailHash:
    c.hashToBlock.withValue(blockHash, loc):
      return ok(loc[].receipts)

  let header = c.baseTxFrame.getBlockHeader(blockHash).valueOr:
    return err("Block header not found")

  c.baseTxFrame.getReceipts(header.receiptsRoot)

func payloadBodyV1FromBaseTo*(c: ForkedChainRef,
                              last: BlockNumber,
                              list: var seq[Opt[ExecutionPayloadBodyV1]]) =
  # return block in reverse order
  var
    branch = c.activeBranch
    branches = newSeqOfCap[BranchRef](c.branches.len)

  while not branch.isNil:
    branches.add(branch)
    branch = branch.parent

  for i in countdown(branches.len-1, 0):
    branch = branches[i]
    for y in 0..<branch.len:
      let bd = addr branch.blocks[y]
      if bd.blk.header.number > last:
        return
      list.add Opt.some(toPayloadBody(bd.blk))

func equalOrAncestorOf*(c: ForkedChainRef, blockHash: Hash32, childHash: Hash32): bool =
  if blockHash == childHash:
    return true

  c.hashToBlock.withValue(childHash, childLoc):
    c.hashToBlock.withValue(blockHash, loc):
      var branch = childLoc.branch
      while not branch.isNil:
        if loc.branch == branch:
          return true
        branch = branch.parent

  false

proc isCanonicalAncestor*(c: ForkedChainRef,
                    blockNumber: BlockNumber,
                    blockHash: Hash32): bool =
  if blockNumber >= c.activeBranch.headNumber:
    return false

  if blockHash == c.activeBranch.headHash:
    return false

  if c.baseBranch.tailNumber < c.activeBranch.headNumber:
    # The current canonical chain in memory is headed by
    # activeBranch.header
    var branch = c.activeBranch
    while not branch.isNil:
      if branch.hasHashAndNumber(blockHash, blockNumber):
        return true
      branch = branch.parent

  # canonical chain in database should have a marker
  # and the marker is block number
  let canonHash = c.baseTxFrame.getBlockHash(blockNumber).valueOr:
    return false
  canonHash == blockHash

iterator txHashInRange*(c: ForkedChainRef, fromHash: Hash32, toHash: Hash32): Hash32 =
  ## toHash should be ancestor of fromHash
  ## exclude base from iteration, new block produced by txpool
  ## should not reach base
  let baseHash = c.baseBranch.tailHash
  var prevHash = fromHash
  while prevHash != baseHash:
    c.hashToBlock.withValue(prevHash, loc) do:
      if toHash == prevHash:
        break
      for tx in loc[].transactions:
        let txHash = computeRlpHash(tx)
        yield txHash
      prevHash = loc[].parentHash
    do:
      break
