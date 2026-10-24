# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [], gcsafe.}

import
  std/[tables, sets, strformat],
  chronicles,
  results,
  chronos,
  metrics,
  ../../common,
  ../../db/[core_db, fcu_db, payload_body_db, tx_frame_db],
  ../../evm/types,
  ../../evm/state,
  ../validate,
  ../inclusion_list,
  ../executor/process_block,
  ../../portal/portal,
  ../../stateless/witness_generation,
  ./forked_chain/[
    chain_desc,
    chain_branch,
    chain_private,
    chain_db,
    block_quarantine]

from std/heapqueue import len
from web3/engine_api_types import ExecutionPayloadBodyV1, ExecutionPayloadBodyV2

logScope:
  topics = "forked chain"

export
  BlockRef,
  ForkedChainRef,
  ImportOutcome,
  ImportErrorKind,
  ImportError,
  common,
  core_db

declareCounter nec_dag_block_processing_duration_seconds,
  "Cumulative time spent processing (validating) blocks"

declareCounter nec_dag_base_updates,
  "Number of base updates (base block moves) performed"

declareCounter nec_dag_base_update_duration_seconds,
  "Cumulative time spent updating the base"

declareCounter nec_dag_prunings, "Number of blocks pruned from the forked chain"

declareCounter nec_dag_pruning_duration_seconds,
  "Cumulative time spent pruning (finalization) branches"

declareGauge nec_dag_heads,
  "Number of candidate chain heads in the forked chain"

declareGauge nec_dag_fcu_head, "" &
  "Block number of the canonical fork-choice head"

const
  BaseDistance = 128'u64
  PersistBatchSize = 4'u64
  EagerBaseQueueSize = 8
    ## How large the base queue can become before we eagerly process base
    ## updates during `importBlock`.
  ImportYieldInterval = 50.milliseconds
    ## Max CPU time to spend on block imports before yielding to the event
    ## loop. Keep well under the peer response timeouts, otherwise the syncer
    ## starts banning honest peers as slow. Yields per batch of work, not per
    ## block, so bulk imports stay fast.
  ImportYieldTimeout = 10.milliseconds
    ## Cap on how long we wait for an idle slot when yielding. Under heavy
    ## network load the loop may never go idle, and we don't want to stop
    ## processing entirely.

proc appendBlock(c: ForkedChainRef,
         parent: BlockRef,
         blk: Block,
         blkHash: Hash32,
         txFrame: CoreDbTxRef,
         txHashes: seq[Hash32]): BlockRef =

  let newBlock = BlockRef(
    header  : blk.header,
    txFrame : txFrame,
    hash    : blkHash,
    parent  : parent,
    txHashes: txHashes,
    isFinalized: false,
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
  nec_dag_heads.set(c.heads.len.int64)

  newBlock

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

  if not c.vmState.isNil() and b.hash == c.vmStateBlockHash:
    c.vmState.dispose()
    c.vmState = nil
    c.vmStateBlockHash.reset()

  # The tx lookup lives in `b.txHashes` and dies with it. Siblings keep their
  # own copy - nothing to unwind here.
  b.txFrame.dispose()

  # Mark it as removed, don't remove it twice
  b.txFrame = nil
  # Clear parent and let GC claim the memory earlier
  b.parent = nil
  b.header.reset()   # frees extraData seq immediately
  b.txHashes.reset()

proc updateHead(c: ForkedChainRef, head: BlockRef) =
  ## Update head if the new head is different from current head. The head is
  ## FC state, saved with the snapshot. The canonical head on disk is the base.
  c.fcuHead = FcuHashAndNumber(hash: head.hash, number: head.number)
  nec_dag_fcu_head.set(head.number.int64)

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

  # Pin canonical payloads before releasing references from dead forks.
  for it in loopNotFinalized(finalized):
    txFrame.finalizeBlockData(it.header)
    it.finalize()

  # There is no point running this expensive algorithm
  # if the chain have no branches, just move it forward.
  if c.heads.len == 1:
    return

  let pruneStart = Moment.now()

  func reachable(head, fin: BlockRef): bool =
    var it = head
    while it.isOk and it.notFinalized:
      it = it.parent
    it == fin

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
        c.deleteBlockData(it)
        c.removeBlockFromCache(it)
        nec_dag_prunings.inc(1)

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

  nec_dag_pruning_duration_seconds.inc((Moment.now() - pruneStart).fseconds())
  nec_dag_heads.set(c.heads.len.int64)

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
  # Before the state: a restart reads the base hash back by number. Lookups
  # written ahead of a crash are on the finalized chain, so they stay valid.
  c.writeCanonicalMappings(base)
  c.com.db.persist(base.txFrame)
  # Everything up to base is on disk now
  base.txFrame.blockHashFn = nil

  # Update baseTxFrame when we about to yield to the event loop
  # and prevent other modules accessing expired baseTxFrame.
  c.baseTxFrame = base.txFrame

  # Cleanup in-memory blocks starting from base backward
  # e.g. B2 backward.
  var count = 0'u

  for it in ancestors(base.parent):
    base.txFrame.deleteTxFrame(it.hash).expect("delete persisted frame")
    c.removeBlockFromCache(it)
    inc count
  # Update base branch
  c.base = base
  c.base.parent = nil
  base.txFrame.deleteTxFrame(base.hash).expect("delete base frame blob")

  # Base block always have finalized marker
  c.base.finalize()

  # If the head is behind base, move it to base too.
  if c.fcuHead.number < c.base.number:
    c.updateHead(c.base)

  if c.dynamicBatchSize:
    # Dynamicly adjust the persistBatchSize based on the recorded run time.
    # The goal here is use the maximum batch size possible without blocking the
    # event loop for too long which could negatively impact the p2p networking.
    # Increasing the batch size can improve performance because the stateroot
    # computation and persist calls are performed less frequently.
    const
      targetTime = 350.milliseconds
      targetTimeDelta = 150.milliseconds
      targetTimeLowerBound = (targetTime - targetTimeDelta).milliseconds
      targetTimeUpperBound = (targetTime + targetTimeDelta).milliseconds
      batchSizeLowerBound = 4
      batchSizeUpperBound = 256

    let
      finishTime = Moment.now()
      runTime = (finishTime - startTime).milliseconds

    if runTime < targetTimeLowerBound and c.persistBatchSize < batchSizeUpperBound:
      c.persistBatchSize = min(c.persistBatchSize + 4, batchSizeUpperBound)
      info "Increased persistBatchSize", runTime, targetTime,
        persistBatchSize = c.persistBatchSize
    elif runTime > targetTimeUpperBound and c.persistBatchSize > batchSizeLowerBound:
      c.persistBatchSize = max(c.persistBatchSize div 2, batchSizeLowerBound)
      info "Decreased persistBatchSize", runTime, targetTime,
        persistBatchSize = c.persistBatchSize

  count

proc processUpdateBase(c: ForkedChainRef) =
  if c.baseQueue.len == 0:
    return

  let
    startTime = Moment.now()
    base = c.baseQueue.popFirst()
    count = c.updateBase(base)

  const minLogInterval = 11.seconds # ~once per slot

  if count > 0:
    let
      endTime = Moment.now()
      updateBaseDur = endTime - startTime

    c.persistedCount += count
    c.lastBaseDur += updateBaseDur

    nec_dag_base_update_duration_seconds.inc(updateBaseDur.fseconds)
    nec_dag_base_updates.inc(1)

    # Log something every time base changes but avoid spamming the INF log
    # during bursts of finalized blocks (ie when light client gives a head)
    logScope:
      nBlocks = c.persistedCount
      head = c.latest.number
      base = c.base.number
      baseHash = c.base.hash.short
      pendingFCU = c.pendingFCU.short
      resolvedFinNum = c.latestFinalized.number
      resolvedFinHash = c.latestFinalized.hash.short
      dbSnapshots = c.baseTxFrame.aTx.db.snapshots.len()
      updateBaseDur = c.lastBaseDur

    if (endTime >= c.lastBaseLogTime + minLogInterval):
      info "Finalized blocks persisted"
      c.lastBaseLogTime = endTime
      c.persistedCount = 0
      c.lastBaseDur.reset()
    else:
      debug "Base updated"

proc processBaseLoop(fc: ForkedChainRef) {.async: (raises: []).} =
  ## Base updates are done in the background to not block the action that led to
  ## them. Each base update moves the base by some amount and then gives the
  ## event loop a chance to run other tasks.
  ##
  ## Typically there will be only a single item in the base queue but if we
  ## didn't know the finalized block number for a while, as happens when using
  ## light clients, the queue can grow significantly. Once the finalized block
  ## number becomes known, we also need to ensure that we base updates proceed
  ## more quickly than blocks are added to the queue on average, otherwise the
  ## queue can grow indefinitely and cause memory issues.
  try:
    # Share the thread with networking and other async tasks, but don't wait
    # too long for an idle slot - we need to update the base faster than we
    # add blocks to the queue on average.
    while fc.baseQueue.len > 0:
      discard await idleAsync().withTimeout(100.milliseconds)
      fc.processUpdateBase()
  except CancelledError:
    # The loop is cancelled when the forked chain is being disposed.
    # We don't want to propagate the exception, just exit the loop.
    debug "processBaseLoop cancelled"
  fc.baseLoop = nil

proc queueUpdateBase(c: ForkedChainRef, base: BlockRef) =
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

  if c.baseLoop.isNil or c.baseLoop.finished():
    c.baseLoop = c.processBaseLoop()

proc validateBlock(
    c: ForkedChainRef,
    parent: BlockRef,
    blk: Block,
    blockAccessList: Opt[BlockAccessListRef],
    inclusionList: Opt[DecodedILRef],
    blkHash: Hash32,
    finalized: bool,
): Result[BlockRef, string] =
  if blkHash == c.pendingFCU:
    # Resolve the hash into latestFinalizedBlockNumber
    discard c.tryUpdatePendingFCU(blkHash, blk.header.number)

  let
    # As a memory optimization we move the HashKeys (kMap) stored in the
    # parent txFrame to the new txFrame unless the block number is one
    # greater than a block which is expected to be persisted based on the
    # persistBatchSize
    moveParentHashKeys = c.persistBatchSize > 1 and (blk.header.number mod c.persistBatchSize) != 1
    parentFrame = parent.txFrame
    txFrame = parentFrame.txFrameBegin(moveParentHashKeys)

  # BLOCKHASH resolves along the block's own branch
  txFrame.blockHashFn = branchBlockHashFn(parent, blk.header.number, blkHash)

  # TODO shortLog-equivalent for eth types
  debug "Validating block",
    blkHash, blk = (
      parentHash: blk.header.parentHash.short,
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
      blockAccessListHash: blk.header.blockAccessListHash
    ),
    parentTxFrame=cast[uint](parentFrame),
    txFrame=cast[uint](txFrame)

  let txHashes = c.processBlock(
      parent, txFrame, blk, blockAccessList, inclusionList, blkHash, finalized).valueOr:
    txFrame.dispose()
    return err(error)

  # Checkpoint creates a snapshot of ancestor changes in txFrame - it is an
  # expensive operation, specially when creating a new branch (ie when blk
  # is being applied to a block that is currently not a head).
  txFrame.checkpoint(blk.header.number, skipSnapshot = false)

  let newBlock = c.appendBlock(parent, blk, blkHash, txFrame, txHashes)

  # Entering base auto forward mode while avoiding forkChoice
  # handled region(head - baseDistance)
  # e.g. live syncing with the tip very far from from our latest head
  let
    offset = c.baseDistance + c.persistBatchSize
    number =
      if offset >= c.latestFinalized.number:
        0.uint64
      else:
        c.latestFinalized.number - offset
  if c.base.number < number:
    # 0 < number => latestFinalized.hash != zero
    let base = c.calculateNewBase(c.latestFinalized.number, c.latest)

    # `base` is the persistence point; the finalization reference passed to
    # `updateFinalized` must never sit *below* the existing finalized markers.
    # During pure auto-forward the current frontier lags `base`, so `base`
    # advances it (and legitimately prunes branches that forked below the new
    # base). But when an earlier `forkChoice` finalized within `baseDistance` of
    # the head, `base` (capped at head - baseDistance) can land *below* that
    # marker; feeding `base` in as the frontier would then make `reachable`
    # prune every head (including `c.latest`), tripping `candidate.isNil.not`.
    # Use the higher of the two - the true finalized frontier on `c.latest`.
    var finalizedFrontier = base
    for it in ancestors(c.latest):
      if not it.notFinalized:
        if it.number > base.number:
          finalizedFrontier = it
        break

    c.updateFinalized(finalizedFrontier, c.latest)
    c.queueUpdateBase(base)

  ok(newBlock)

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
      ): T =
  ## Constructor that uses the current database ledger state for initialising.
  ## This state coincides with the canonical head that would be used for
  ## setting up the descriptor.
  ##
  ## The persisted Aristo checkpoint selects the base. It is also the head
  ## until `deserialize()` restores the fork choice saved with the snapshot.
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
      header  : baseHeader,
      txFrame : baseTxFrame,
      hash    : baseHash,
      parent  : BlockRef(nil),
    )
    fcuHead = FcuHashAndNumber(hash: baseHash, number: base)
    fcuSafe = fcuHead
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
      importLock:       newAsyncLock(),
      badBlocks:        LruCache[Hash32, (Block, Opt[BlockAccessListRef])].init(100),
    )

  # updateFinalized will stop ancestor lineage
  # traversal if parent have finalized marker.
  baseBlock.finalize()

  fc

proc refresh*(fc: ForkedChainRef, eagerStateRoot = false) =
  ## Flush internal caches and reassign database.
  # TODO rewrite this function - it should not need to reset everything since
  #      the FC necessarily must be empty as long as there's no base
  doAssert false, "TODO fix this to only update the relevant parts and assert that the others haven't changed"
  let newFc = ForkedChainRef.init(
    com = fc.com,
    baseDistance = fc.baseDistance,
    persistBatchSize = fc.persistBatchSize,
    dynamicBatchSize = fc.dynamicBatchSize,
    eagerStateRoot)                                 # seems to be unused, though

  fc[].reset                                        # clear desctiptor

  # Copy base settings
  fc.com = newFc.com
  fc.base = newFc.base
  fc.latest = newFc.latest
  fc.heads = newFc.heads
  fc.hashToBlock = newFc.hashToBlock
  fc.baseTxFrame = newFc.baseTxFrame
  fc.baseDistance = newFc.baseDistance
  fc.persistBatchSize = newFc.persistBatchSize
  fc.dynamicBatchSize = newFc.dynamicBatchSize
  fc.quarantine = newFc.quarantine
  fc.fcuHead = newFc.fcuHead
  fc.fcuSafe = newFc.fcuSafe
  fc.baseQueue = newFc.baseQueue
  fc.lastBaseLogTime = newFc.lastBaseLogTime
  fc.lastImportYield = newFc.lastImportYield
  fc.badBlocks = newFc.badBlocks
  fc.importLock = newFc.importLock


  # Force GC to clean up
  newFc[].reset

proc importBlock*(
    c: ForkedChainRef,
    blk: Block,
    blockAccessList = Opt.none(BlockAccessListRef),
    inclusionList = Opt.none(DecodedILRef),
    finalized = false,
    immediate = false,
  ): Future[Result[ImportOutcome, ImportError]] {.async: (raises: [CancelledError]).} =
  ## Try to import block to canonical or side chain.
  ##
  ## Classifies the block and returns a typed verdict instead of forcing the
  ## caller to second-guess `FC` state:
  ##  * `ok(Valid)`           - newly validated and linked
  ##  * `ok(AlreadyObserved)` - block already present by hash
  ##  * `err(Invalid)`        - genuine validation failure
  ##  * `err(Orphaned)`       - branch cut off at/below finalized (drop forward)
  ##  * `err(MissingParent)`  - parent not yet present (above finalized)
  ## The `err.msg` text is unchanged from the previous string interface.
  ##
  ## `finalized` should be set to true for blocks that are known to be finalized
  ## already per the latest fork choice update from the consensus client, for
  ## example by following the header chain back from the fcu hash - in such
  ## cases, we perform state root checking in bulk while writing the state to
  ## disk (instead of once for every block).
  template header(): Header =
    blk.header

  let blkHash = header.computeBlockHash
  logScope:
    blockHash = blkHash.short
    parentHash = header.parentHash.short
    number = header.number

  # Make sure the event loop has a chance to run between block validations.
  # Networking and block processing share this thread, so we hand it back
  # regularly or network reads stall and peers time us out. We yield per
  # batch of work (not per block): yielding for every single block costs up to
  # the timeout for each one and makes bulk imports (e.g. bootstrap) much
  # slower than they need to be.
  if ImportYieldInterval <= Moment.now() - c.lastImportYield and not immediate:
    discard await idleAsync().withTimeout(ImportYieldTimeout)
    c.lastImportYield = Moment.now()

  # This lock ensures that quarantine blocks are imported after their parent but
  # but before other calls to importBlock - it also ensures that if two calls to
  # `importBlock` are racing to import the same block, only one of them will
  # process the block.
  await c.importLock.acquire()
  defer: c.importLock.release2()

  # Already observed: the block content arrived earlier (from us or a concurrent
  # importer such as `el_sync`). Nothing to do.
  if c.hashToBlock.hasKey(blkHash):
    debug "Block already observed"
    return ok(AlreadyObserved)

  # Check if there's a long queue of base updates and if so, run one base update
  # before validating the block - this ensures that at least some blocks are
  # released from memory before adding another one.
  # A large base queue occurs when finality makes a big jump, such as when the
  # CL is feeding us light client data - in other words, this base update should
  # typically not happen an already synced client.
  if c.baseQueue.len > EagerBaseQueueSize:
    c.processUpdateBase()

  let parent = c.hashToBlock.getOrDefault(header.parentHash)
  if not parent.isOk:
    # Parent is not in the in-memory `(base, latest]` window. Classify by the
    # block's height relative to `base`/`latest` (the error channel is preserved -
    # same `msg` as the previous `err("Block is not part of valid chain")`).
    return
      if header.number <= c.latest.number:
        # The parent is gone, but this block may itself be the canonical block at
        # this height that was already imported and then pruned from memory once it
        # fell at/below `base` (finality cut off its parent). This happens when a
        # concurrent importer such as `el_sync` advances and finalizes the chain past
        # a stale sync target. Tell that apart from a genuine dead fork via the
        # persisted canonical marker (reorg-safe: matched by hash, not by number).
        if header.number <= c.base.number and
            c.baseTxFrame.getBlockHash(header.number).valueOr(default(Hash32)) == blkHash:
          debug "Block already observed"
          ok(AlreadyObserved)
        else:
          # The in-memory chain already spans this height yet the parent is gone: the
          # parent's branch was pruned (finality cut it off), so this block is on a
          # dead fork. `c.latest` is the reliable frontier here - `c.latestFinalized`
          # can lag until a matching fork-choice block is imported.
          debug "Block orphaned"
          err(ImportError(kind: Orphaned, msg: "Block is not part of valid chain"))
      else:
        # The chain has not reached this height yet: the parent may still arrive.
        # Quarantine and wait.
        c.quarantine.addOrphan(blkHash, blk, blockAccessList, inclusionList)
        debug "Parent not found"
        err(ImportError(kind: MissingParent, msg: "Block parent not found"))

  # TODO: If engine API keep importing blocks
  # but not finalized it, e.g. current chain length > StagedBlocksThreshold
  # We need to persist some of the in-memory stuff
  # to a "staging area" or disk-backed memory but it must not afect `base`.
  # `base` is the point of no return, we only update it on finality.

  # Setting the finalized flag to true here has the effect of skipping the
  # stateroot check for performance reasons.
  let
    isFinalized = finalized or blk.header.number <= c.latestFinalized.number
    startTime = Moment.now()
    newParent = c.validateBlock(parent, blk, blockAccessList, inclusionList, blkHash, isFinalized).valueOr:
      debug "Block invalid", validationDur = Moment.now() - startTime, error
      return err(ImportError(kind: Invalid, msg: error))

    orphan = c.quarantine.popOrphan(newParent.hash)

  let validationDur = Moment.now() - startTime
  nec_dag_block_processing_duration_seconds.inc(validationDur.fseconds())
  debug "Block validated", validationDur

  if orphan.isSome():
    # Enqueue the orphan for import after its parent, but before any other blocks. We're
    # still holding the lock at this point and discarding the future that
    # represents the orphan task - the return value is not used any more because
    # the caller that enqueued the orphan has already moved on with
    # `MissingParent`.
    discard c.importBlock(orphan.get()[0], orphan.get()[1], orphan.get()[2])

  ok(Valid)

proc forkChoice*(
    c: ForkedChainRef,
    headHash: Hash32,
    finalizedHash: Hash32,
    safeHash: Hash32 = zeroHash32,
): Result[void, string] =
  if finalizedHash != zeroHash32:
    c.pendingFCU = finalizedHash

  if safeHash != zeroHash32:
    let safe = c.hashToBlock.getOrDefault(safeHash)
    if safe.isOk:
      c.fcuSafe.number = safe.number
      c.fcuSafe.hash = safeHash

  if headHash == c.latest.hash:
    if finalizedHash == zeroHash32:
      # Do nothing if the new head already our current head
      # and there is no request to new finality.
      return ok()

  let
    # Find the unique branch where `headHash` is a member of.
    head = ?c.findHeadPos(headHash)

  # Head maybe moved backward or moved to other branch.
  c.updateHead(head)
  if finalizedHash == zeroHash32:
    # Do nothing else if there is no request to new finality.
    return ok()

  let
    # Finalized block must be parent or on the new canonical chain which is
    # represented by `head`.
    finalized = ?c.findFinalizedPos(finalizedHash, head)

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
  c.queueUpdateBase(base)

  ok()

proc setHead*(c: ForkedChainRef, headHash: Hash32): Result[void, string] =
  ## Forcibly reset the chain head to `headHash`, discarding every in-memory
  ## block that is not an ancestor of the new head - both the blocks above it
  ## on its own branch and any competing branches. Discarded blocks can be
  ## imported again afterwards.
  ##
  ## The new head must be in the in-memory window: blocks at or below `base`
  ## have been persisted and cannot be rewound, and finalized blocks cannot
  ## be discarded, so the head can only move to the latest finalized block
  ## or one of its descendants.
  ##
  ## This is a destructive debug/testing helper backing `debug_setHead` - it
  ## bypasses the usual fork choice rules.
  let head = ?c.findHeadPos(headHash)

  # Blocks on the new head's lineage survive, everything else is removed.
  var keep = initHashSet[Hash32]()
  for it in ancestors(head):
    keep.incl it.hash

  # Refuse to discard finalized blocks (which may already be queued for
  # persisting). Checked up front so that no blocks are removed on error.
  for branchHead in c.heads:
    for it in ancestors(branchHead):
      if it.hash in keep:
        break
      if not it.notFinalized:
        return err("Cannot set head to " & headHash.short &
          ": finalized block " & it.hash.short & " would be discarded")

  for branchHead in c.heads:
    # Walk each branch tip first so that children are disposed before parents.
    for it in ancestors(branchHead):
      if it.hash in keep or it.txFrame.isNil:
        # Reached the new head's lineage, or a segment already removed while
        # walking a previous branch.
        break
      c.removeBlockFromCache(it)

  c.heads = @[head]
  c.latest = head
  c.updateHead(head)

  if c.fcuSafe.number > head.number:
    # The old safe block was discarded, clamp it to the new head.
    c.fcuSafe = FcuHashAndNumber(hash: head.hash, number: head.number)

  nec_dag_heads.set(c.heads.len.int64)

  ok()

proc flushBaseLoop*(c: ForkedChainRef, dropQueue = false) {.async: (raises: []).} =
  if c.baseLoop.isNil.not and c.baseLoop.finished().not:
    if dropQueue:
      c.baseQueue.clear()

    debug "Waiting for base loop to finish",
      baseQueueLen = c.baseQueue.len,
      baseNumber = c.base.number,
      latestNumber = c.latest.number
    await c.baseLoop

  if not c.vmState.isNil():
    c.vmState.dispose()
    c.vmState = nil
    c.vmStateBlockHash.reset()

func resolvedFinHash*(c: ForkedChainRef): Hash32 =
  c.latestFinalized.hash

func resolvedFinNumber*(c: ForkedChainRef): uint64 =
  c.latestFinalized.number

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

func isInMemory*(c: ForkedChainRef, blockHash: Hash32): bool =
  c.hashToBlock.hasKey(blockHash)

func isHistoryExpiryActive*(c: ForkedChainRef): bool =
  not c.portal.isNil

func isPortalActive(c: ForkedChainRef): bool =
  (not c.portal.isNil) and c.portal.portalEnabled

proc memoryTxHashesForBlock*(c: ForkedChainRef, blockHash: Hash32): Opt[seq[Hash32]] =
  ## Tx hashes of an in-memory block, in block order.
  ## `Opt.none` = not in memory, or no txs; caller resolves them one by one.
  let b = c.hashToBlock.getOrDefault(blockHash)
  if b.isNil or b.txHashes.len == 0:
    return Opt.none(seq[Hash32])

  Opt.some(b.txHashes)

proc latestBlock*(c: ForkedChainRef): Result[Block, string] =
  c.latest.txFrame.getEthBlock(c.latest.hash)

proc getBadBlocks*(c: ForkedChainRef): seq[(Block, Opt[BlockAccessListRef])] =
  var blks: seq[(Block, Opt[BlockAccessListRef])]
  for badBlock in c.badBlocks.values():
    blks.add(badBlock)
  blks

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
  c.hashToBlock.withValue(c.latestFinalized.hash, loc):
    return loc[].header

  c.base.header

func safeHeader*(c: ForkedChainRef): Header =
  c.hashToBlock.withValue(c.fcuSafe.hash, loc):
    return loc[].header

  c.base.header

proc finalizedBlock*(c: ForkedChainRef): Result[Block, string] =
  c.hashToBlock.withValue(c.latestFinalized.hash, loc):
    return loc[].txFrame.getEthBlock(loc[].hash)

  c.baseTxFrame.getEthBlock(c.base.hash)

proc safeBlock*(c: ForkedChainRef): Result[Block, string] =
  c.hashToBlock.withValue(c.fcuSafe.hash, loc):
    return loc[].txFrame.getEthBlock(loc[].hash)

  c.baseTxFrame.getEthBlock(c.base.hash)

proc persistedHeaderByHash(c: ForkedChainRef, blockHash: Hash32): Result[Header, string] =
  ## Header of base or a canonical block below it. Import writes headers to
  ## disk before the block becomes base, so after a crash the disk also holds
  ## headers of blocks this chain does not track.
  let header = ?c.baseTxFrame.getBlockHeader(blockHash)
  if header.number > c.base.number or
      c.baseTxFrame.getBlockHash(header.number).valueOr(default(Hash32)) != blockHash:
    return err("No block with hash " & $blockHash)
  ok(header)

proc headerByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Header, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return ok(loc[].header)

  c.persistedHeaderByHash(blockHash)

proc txDetailsByTxHash*(c: ForkedChainRef, txHash: Hash32): Result[(Hash32, uint64), string] =
  ## Locate `txHash` on the `latest` lineage: `(block hash, index)`.
  ##
  ## Branch-local by construction: blocks above base carry their own tx hashes,
  ## so a sibling holding the same tx can neither shadow this one, nor take it
  ## down when pruned. The lookup on disk covers base and below.
  for it in ancestors(c.latest):
    let index = it.txHashes.find(txHash)
    if index >= 0:
      return ok((it.hash, uint64 index))

  let txDetails = ?c.baseTxFrame.getTransactionKey(txHash)

  # A miss reads back as the zero key. Genesis has no txs, so block 0 is a miss.
  if txDetails.blockNumber == 0:
    return err("Transaction not found: " & txHash.short)

  let
    header = ?c.headerByNumber(txDetails.blockNumber)
    blockHash = header.computeBlockHash
  return ok((blockHash, txDetails.index))

# TODO: Doesn't fetch data from portal
# Aristo returns empty txs for both non-existent blocks and existing blocks with no txs [ Solve ? ]
proc blockBodyByHash*(c: ForkedChainRef, blockHash: Hash32): Result[BlockBody, string] =
  c.hashToBlock.withValue(blockHash, loc):
    return loc[].txFrame.getBlockBody(loc[].header)
  c.baseTxFrame.getBlockBody(?c.persistedHeaderByHash(blockHash))

proc blockByHash*(c: ForkedChainRef, blockHash: Hash32): Result[Block, string] =
  # used by getPayloadBodiesByHash
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/shanghai.md#specification-3
  # 4. Client software MAY NOT respond to requests for finalized blocks by hash.
  c.hashToBlock.withValue(blockHash, loc):
    return loc[].txFrame.getEthBlock(loc[].hash)
  var header = ?c.persistedHeaderByHash(blockHash)
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
    let blk = ?loc[].txFrame.getEthBlock(loc[].hash)
    return ok(toPayloadBodyV1(blk))

  var header = ?c.persistedHeaderByHash(blockHash)
  var blk = c.baseTxFrame.getExecutionPayloadBodyV1(header)

  if blk.isErr:
    # Serve portal data if block not found in db
    if c.isPortalActive:
      var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
      # Same as above
      return ok(toPayloadBodyV1(EthBlock.init(move(header), move(blockBodyPortal))))

  move(blk)

proc payloadBodyV2ByHash*(c: ForkedChainRef, blockHash: Hash32): Result[ExecutionPayloadBodyV2, string] =
  c.hashToBlock.withValue(blockHash, loc):
    let blk = ?loc[].txFrame.getEthBlock(loc[].hash)
    return ok(toPayloadBodyV2(blk, ?loc[].txFrame.getBlockAccessList(loc[].hash)))

  var header = ?c.persistedHeaderByHash(blockHash)
  var blk = c.baseTxFrame.getExecutionPayloadBodyV2(header)

  if blk.isErr:
    # Serve portal data if block not found in db
    if c.isPortalActive:
      var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
      # Same as above
      return ok(toPayloadBodyV2(
        EthBlock.init(move(header), move(blockBodyPortal)),
          ?c.baseTxFrame.getBlockAccessList(header.computeRlpHash())))

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
        return ok(toPayloadBodyV1(EthBlock.init(move(header), move(blockBodyPortal))))

    return blk

  for it in ancestors(c.latest):
    if number >= it.number:
      let blk = ?it.txFrame.getEthBlock(it.hash)
      return ok(toPayloadBodyV1(blk))

  err("Block not found, number = " & $number)

proc payloadBodyV2ByNumber*(c: ForkedChainRef, number: BlockNumber): Result[ExecutionPayloadBodyV2, string] =
  if number > c.latest.number:
    return err("Requested block number not exists: " & $number)

  if number <= c.base.number:
    var header = ?c.baseTxFrame.getBlockHeader(number)
    let blk = c.baseTxFrame.getExecutionPayloadBodyV2(header)

    if blk.isErr:
      # Serve portal data if block not found in db
      if c.isPortalActive:
        var blockBodyPortal = ?c.portal.getBlockBodyByHeader(header)
        # same as above
        return ok(toPayloadBodyV2(
          EthBlock.init(move(header), move(blockBodyPortal)),
            ?c.baseTxFrame.getBlockAccessList(header.computeRlpHash())))

    return blk

  for it in ancestors(c.latest):
    if number >= it.number:
      let blk = ?it.txFrame.getEthBlock(it.hash)
      return ok(toPayloadBodyV2(blk, ?it.txFrame.getBlockAccessList(it.hash)))

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
      return it.txFrame.getEthBlock(it.hash)

  err("Block not found, number = " & $number)

proc blockHeader*(c: ForkedChainRef, blk: BlockHashOrNumber): Result[Header, string] =
  if blk.isHash:
    return c.headerByHash(blk.hash)
  c.headerByNumber(blk.number)

proc receiptsByBlockHash*(c: ForkedChainRef, blockHash: Hash32): Result[seq[StoredReceipt], string] =
  if blockHash != c.base.hash:
    c.hashToBlock.withValue(blockHash, loc):
      let header = ?loc[].txFrame.getBlockHeader(loc[].hash)
      return loc[].txFrame.getReceipts(header.receiptsRoot)

  let header = c.persistedHeaderByHash(blockHash).valueOr:
    return err("Block header not found")

  c.baseTxFrame.getReceipts(header.receiptsRoot)

proc receiptByBlockHashAndIndex*(c: ForkedChainRef, blockHash: Hash32, index: uint64): Result[StoredReceipt, string] =
  if blockHash != c.base.hash:
    c.hashToBlock.withValue(blockHash, loc):
      let header = ?loc[].txFrame.getBlockHeader(loc[].hash)
      return loc[].txFrame.getReceiptByIndex(header.receiptsRoot, index.uint16)

  let header = c.persistedHeaderByHash(blockHash).valueOr:
    return err("Block header not found")

  c.baseTxFrame.getReceiptByIndex(header.receiptsRoot, index.uint16)

proc txByBlockHashAndIndex*(c: ForkedChainRef, blockHash: Hash32, index: uint64): Result[Transaction, string] =
  if blockHash != c.base.hash:
    c.hashToBlock.withValue(blockHash, loc):
      return loc[].txFrame.getTransactionByIndex(loc[].header.txRoot, index.uint16)

  let header = c.persistedHeaderByHash(blockHash).valueOr:
    return err("Block header not found")

  c.baseTxFrame.getTransactionByIndex(header.txRoot, index.uint16)

proc payloadBodyV1InMemory*(c: ForkedChainRef,
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
    let blk = y.txFrame.getEthBlock(y.hash).valueOr: continue
    list.add Opt.some(toPayloadBodyV1(blk))

proc payloadBodyV2InMemory*(c: ForkedChainRef,
                            first: BlockNumber,
                            last: BlockNumber,
                            list: var seq[Opt[ExecutionPayloadBodyV2]]) =
  var
    blocks = newSeqOfCap[BlockRef](last-first+1)

  for it in ancestors(c.latest):
    if it.number >= first and it.number <= last:
      blocks.add(it)

  for i in countdown(blocks.len-1, 0):
    let y = blocks[i]
    let blk = y.txFrame.getEthBlock(y.hash).valueOr: continue
    list.add Opt.some(toPayloadBodyV2(blk, y.txFrame.getBlockAccessList(y.hash).expect("ok")))

func equalOrAncestorOf*(c: ForkedChainRef, blockHash: Hash32, headHash: Hash32): bool =
  if blockHash == headHash:
    return true

  let head = c.hashToBlock.getOrDefault(headHash)
  for it in ancestors(head):
    if it.hash == blockHash:
      return true

  false

func knownFinalizedBlock(c: ForkedChainRef, finalizedBlockHash: Hash32): BlockRef =
  let b = c.hashToBlock.getOrDefault(finalizedBlockHash)
  if b.isNil.not:
    return b
  c.hashToBlock.getOrDefault(c.latestFinalized.hash)

proc isCanonicalAndFinalizedAncestor*(c: ForkedChainRef,
                    blockNumber: BlockNumber,
                    blockHash: Hash32,
                    finalizedBlockHash: Hash32): bool =
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.7/src/engine/paris.md#specification-1
  # Client software MAY skip an update of the forkchoice state and MUST NOT
  # begin a payload build process if there is a known finalizedBlockHash and
  # forkchoiceState.headBlockHash references a VALID ancestor of the latest
  # known finalized block, i.e. the ancestor passed payload validation process
  # and deemed VALID.

  if blockHash == finalizedBlockHash:
    return false

  let b = c.knownFinalizedBlock(finalizedBlockHash)
  if b.isNil:
    return false

  if blockNumber >= b.number:
    return false

  if c.base.number < b.number:
    for it in ancestors(b):
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
    for txHash in it.txHashes:
      yield txHash

proc getBlockAccessList*(c: ForkedChainRef, blockHash: Hash32): Opt[BlockAccessList] =
  let bal = c.txFrame(blockHash).getBlockAccessList(blockHash).valueOr:
    return Opt.none(BlockAccessList)

  bal.map(proc (v: auto): auto = v[])

proc getExecutionWitness*(
    c: ForkedChainRef, blockHash: Hash32
): Result[ExecutionWitnessWithKeys, string] =
  ## Return the execution witness created when importing the given block
  let txFrame = c.txFrame(blockHash).txFrameBegin()
  defer:
    txFrame.dispose()

  let witness = txFrame.getWitness(blockHash).valueOr:
    return err("Witness not found")

  ok(ExecutionWitnessWithKeys.build(witness, txFrame))

proc generateExecutionWitness*(
    c: ForkedChainRef, blk: Block
): Result[ExecutionWitnessWithKeys, string] =
  ## Build the execution witness for `blk` on demand by re-executing it against
  ## its parent state, without requiring `--stateless-provider` and without
  ## persisting anything. Works for a freshly imported or already known block as
  ## long as the parent state is available, else the state root check errors.
  template header(): Header = blk.header

  let parentHeader = ?c.headerByHash(header.parentHash)

  # Execute on a throwaway frame so the shared parent state is never modified.
  let
    parentFrame = c.txFrame(header.parentHash)
    txFrame = parentFrame.txFrameBegin()
  defer:
    txFrame.dispose()

  let vmState = BaseVMState()
  vmState.init(parentHeader, header, c.com, txFrame, collectWitness = true)

  # No block access list keeps execution sequential (parallel skips witness keys).
  ?vmState.processBlock(
    blk,
    blockAccessList = Opt.none(BlockAccessListRef),
    skipValidation = true,
    skipReceipts = true,
    skipUncles = true,
    skipStateRootCheck = false,
    skipPostExecBalCheck = true)

  let
    preStateLedger = LedgerRef.init(parentFrame)
    witness = Witness.build(preStateLedger, vmState.ledger, parentHeader, header)

  ok(ExecutionWitnessWithKeys.build(witness, txFrame))
