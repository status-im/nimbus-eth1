# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  chronicles,
  chronos,
  eth/p2p,
  stew/keyed_queue,
  ../../../misc/[best_pivot, block_queue, sync_ctrl, ticker],
  ../../../protocol,
  "../.."/[range_desc, worker_desc],
  ../db/[snapdb_desc, snapdb_persistent],
  ../get/get_error,
  ./pass_desc

type
  FullPassCtxRef = ref object of RootRef
    ## Pass local descriptor extension for full sync process
    startNumber: Option[BlockNumber]  ## History starts here (used for logging)
    pivot: BestPivotCtxRef            ## Global pivot descriptor
    bCtx: BlockQueueCtxRef            ## Global block queue descriptor
    suspendAt: BlockNumber            ## Suspend if persistent head is larger

  FullPassBuddyRef = ref object of RootRef
    ## Pass local descriptor extension for full sync process
    pivot: BestPivotWorkerRef         ## Local pivot worker descriptor
    queue: BlockQueueWorkerRef        ## Block queue worker

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

  dumpDatabaseOnRollOver = false # or true # <--- will go away (debugging only)
    ## Dump database before switching to full sync (debugging, testing)

when dumpDatabaseOnRollOver:               # <--- will go away (debugging only)
  import ../../../../../tests/replay/undump_kvp

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Full worker " & info

template ignoreException(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    error "Exception at " & info & ":", name=($e.name), msg=(e.msg)

# ------------------------------------------------------------------------------
# Private getter/setter
# ------------------------------------------------------------------------------

proc pass(pool: SnapCtxData): auto =
  ## Getter, pass local descriptor
  pool.full.FullPassCtxRef

proc pass(only: SnapBuddyData): auto =
  ## Getter, pass local descriptor
  only.full.FullPassBuddyRef

proc `pass=`(pool: var SnapCtxData; val: FullPassCtxRef) =
  ## Setter, pass local descriptor
  pool.full = val

proc `pass=`(only: var SnapBuddyData; val: FullPassBuddyRef) =
  ## Getter, pass local descriptor
  only.full = val

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc resumeAtNumber(ctx: SnapCtxRef): BlockNumber =
  ## Resume full sync (if any)
  ignoreException("resumeAtNumber"):
    const nBackBlocks = maxHeadersFetch div 2
    let bestNumber = ctx.chain.db.getCanonicalHead().blockNumber
    if nBackBlocks < bestNumber:
      return bestNumber - nBackBlocks


proc tickerUpdater(ctx: SnapCtxRef): TickerFullStatsUpdater =
  result = proc: TickerFullStats =
    let full = ctx.pool.pass

    var stats: BlockQueueStats
    full.bCtx.blockQueueStats(stats)

    let suspended = 0 < full.suspendAt and full.suspendAt <= stats.topAccepted

    TickerFullStats(
      pivotBlock:      ctx.pool.pass.startNumber,
      topPersistent:   stats.topAccepted,
      nextStaged:      stats.nextStaged,
      nextUnprocessed: stats.nextUnprocessed,
      nStagedQueue:    stats.nStagedQueue,
      suspended:       suspended,
      reOrg:           stats.reOrg)


proc processStaged(buddy: SnapBuddyRef): bool =
  ## Fetch a work item from the `staged` queue an process it to be
  ## stored on the persistent block chain.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    chainDb = buddy.ctx.chain.db
    chain = buddy.ctx.chain
    bq = buddy.only.pass.queue

    # Get a work item, a list of headers + bodies
    wi = block:
      let rc = bq.blockQueueFetchStaged()
      if rc.isErr:
        return false
      rc.value

    #startNumber = wi.headers[0].blockNumber -- unused

  # Store in persistent database
  try:
    if chain.persistBlocks(wi.headers, wi.bodies) == ValidationResult.OK:
      bq.blockQueueAccept(wi)
      return true
  except CatchableError as e:
    error logTxt "storing persistent blocks failed", peer, range=($wi.blocks),
      name=($e.name), msg=(e.msg)

  # Something went wrong. Recycle work item (needs to be re-fetched, anyway)
  let
    parentHash = wi.headers[0].parentHash
  try:
    # Check whether hash of the first block is consistent
    var parent: BlockHeader
    if chainDb.getBlockHeader(parentHash, parent):
      # First block parent is ok, so there might be other problems. Re-fetch
      # the blocks from another peer.
      trace "Storing persistent blocks failed", peer, range=($wi.blocks)
      bq.blockQueueRecycle(wi)
      buddy.ctrl.zombie = true
      return false
  except CatchableError as e:
    error logTxt "failed to access parent blocks", peer,
      blockNumber=wi.headers[0].blockNumber.toStr, name=($e.name), msg=e.msg

  # Parent block header problem, so we might be in the middle of a re-org.
  # Set single mode backtrack following the offending parent hash.
  bq.blockQueueBacktrackFrom(wi)
  buddy.ctrl.multiOk = false

  if wi.topHash.isNone:
    # Assuming that currently staged entries are on the wrong branch
    bq.blockQueueRecycleStaged()
    notice logTxt "starting chain re-org backtrack work item", peer,
      range=($wi.blocks)
  else:
    # Leave that block range in the staged list
    trace logTxt "resuming chain re-org backtrack work item", peer,
      range=($wi.blocks)
    discard

  return false

proc suspendDownload(buddy: SnapBuddyRef): bool =
  ## Check whether downloading should be suspended
  let
    ctx = buddy.ctx
    full = ctx.pool.pass

  # Update from RPC magic
  if full.suspendAt < ctx.pool.beaconHeader.blockNumber:
    full.suspendAt = ctx.pool.beaconHeader.blockNumber

  # Optionaly, some external update request
  if ctx.exCtrlFile.isSome:
    # Needs to be read as second line (index 1)
    let rc = ctx.exCtrlFile.syncCtrlBlockNumberFromFile(1)
    if rc.isOk and full.suspendAt < rc.value:
      full.suspendAt = rc.value

  # Return `true` if download should be suspended
  if 0 < full.suspendAt:
    return full.suspendAt <= buddy.only.pass.queue.topAccepted

# ------------------------------------------------------------------------------
# Private functions, full sync admin handlers
# ------------------------------------------------------------------------------

proc fullSyncSetup(ctx: SnapCtxRef) =
  # Set up descriptor
  let full = FullPassCtxRef()
  ctx.pool.pass = full

  # Initialise full sync, resume from previous download (if any)
  let blockNumber = ctx.resumeAtNumber()
  if 0 < blockNumber:
    full.startNumber = some(blockNumber)
    full.bCtx = BlockQueueCtxRef.init(blockNumber + 1)
  else:
    full.bCtx = BlockQueueCtxRef.init()

  # Initialise peer pivots in relaxed mode (not waiting for agreeing peers)
  full.pivot = BestPivotCtxRef.init(rng=ctx.pool.rng, minPeers=0)

  # Update ticker
  ctx.pool.ticker.init(cb = ctx.tickerUpdater())

proc fullSyncRelease(ctx: SnapCtxRef) =
  ctx.pool.ticker.stop()
  ctx.pool.pass = nil


proc fullSyncStart(buddy: SnapBuddyRef): bool =
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if peer.supports(protocol.eth) and peer.state(protocol.eth).initialized:
    let p = ctx.pool.pass

    buddy.only.pass = FullPassBuddyRef()
    buddy.only.pass.queue = BlockQueueWorkerRef.init(p.bCtx, buddy.ctrl, peer)
    buddy.only.pass.pivot = BestPivotWorkerRef.init(p.pivot, buddy.ctrl, peer)

    ctx.pool.ticker.startBuddy()
    buddy.ctrl.multiOk = false # confirm default mode for soft restart
    buddy.only.errors = GetErrorStatsRef()
    return true

proc fullSyncStop(buddy: SnapBuddyRef) =
  buddy.only.pass.pivot.clear()
  buddy.ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Private functions, full sync action handlers
# ------------------------------------------------------------------------------

proc fullSyncDaemon(ctx: SnapCtxRef) {.async.} =
  ctx.daemon = false


proc fullSyncPool(buddy: SnapBuddyRef, last: bool; laps: int): bool =
  let ctx = buddy.ctx

  # There is a soft re-setup after switch over to full sync mode if a pivot
  # block header is available initialised from outside, i.e. snap sync swich.
  if ctx.pool.fullHeader.isSome:
    let
      stateHeader = ctx.pool.fullHeader.unsafeGet
      initFullSync = ctx.pool.pass.startNumber.isNone

    # Re-assign start number for logging (instead of genesis)
    ctx.pool.pass.startNumber = some(stateHeader.blockNumber)

    if initFullSync:
      # Reinitialise block queue descriptor relative to current pivot
      ctx.pool.pass.bCtx = BlockQueueCtxRef.init(stateHeader.blockNumber + 1)

      # Store pivot as parent hash in database
      ctx.pool.snapDb.kvDb.persistentBlockHeaderPut stateHeader

      # Instead of genesis.
      ctx.chain.com.startOfHistory = stateHeader.blockHash

      when dumpDatabaseOnRollOver:         # <--- will go away (debugging only)
        # Dump database ...                  <--- will go away (debugging only)
        let nRecords =                     # <--- will go away (debugging only)
          ctx.pool.snapDb.rockDb.dumpAllDb # <--- will go away (debugging only)
        trace logTxt "dumped block chain database", nRecords

    # Kick off ticker (was stopped by snap `release()` method)
    ctx.pool.ticker.start()

    # Reset so that this action would not be triggered, again
    ctx.pool.fullHeader = none(BlockHeader)

  # Soft re-start buddy peers if on the second lap.
  if 0 < laps and ctx.pool.pass.startNumber.isSome:
    if not buddy.fullSyncStart():
      # Start() method failed => wait for another peer
      buddy.ctrl.stopped = true
    if last:
      trace logTxt "soft restart done", peer=buddy.peer, last, laps,
        pivot=ctx.pool.pass.startNumber.toStr,
        mode=ctx.pool.syncMode.active, state= buddy.ctrl.state
    return false # does stop magically when looping over peers is exhausted

  # Mind the gap, fill in if necessary (function is peer independent)
  buddy.only.pass.queue.blockQueueGrout()
  true # Stop after running once regardless of peer


proc fullSyncSingle(buddy: SnapBuddyRef) {.async.} =
  let
    pv = buddy.only.pass.pivot
    bq = buddy.only.pass.queue
    bNum = bq.bestNumber.get(otherwise = bq.topAccepted + 1)

  # Negotiate in order to derive the pivot header from this `peer`.
  if await pv.pivotNegotiate(some(bNum)):
    # Update/activate `bestNumber` from the pivot header
    bq.bestNumber = some(pv.pivotHeader.value.blockNumber)
    buddy.ctrl.multiOk = true
    when extraTraceMessages:
      trace logTxt "pivot accepted", peer=buddy.peer,
        minNumber=bNum.toStr, bestNumber=bq.bestNumber.unsafeGet.toStr
    return

  if buddy.ctrl.stopped:
    when extraTraceMessages:
      trace logTxt "single mode stopped", peer=buddy.peer
    return # done with this buddy

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.)
  await sleepAsync 300.milliseconds


proc fullSyncMulti(buddy: SnapBuddyRef): Future[void] {.async.} =
  ## Full sync processing
  let
    ctx = buddy.ctx
    bq = buddy.only.pass.queue

  if buddy.suspendDownload:
    # Sleep for a while, then leave
    await sleepAsync(10.seconds)
    return

  # Fetch work item
  let rc = await bq.blockQueueWorker()
  if rc.isErr:
    if rc.error == StagedQueueOverflow:
      # Mind the gap: Turn on pool mode if there are too may staged items.
      ctx.poolMode = true
    else:
      trace logTxt "error", peer=buddy.peer, error=rc.error
      return

  # Update persistent database
  while buddy.processStaged() and not buddy.ctrl.stopped:
    trace logTxt "multi processed", peer=buddy.peer
    # Allow thread switch as `persistBlocks()` might be slow
    await sleepAsync(10.milliseconds)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc passFull*: auto =
  ## Return full sync handler environment
  PassActorRef(
    setup:   fullSyncSetup,
    release: fullSyncRelease,
    start:   fullSyncStart,
    stop:    fullSyncStop,
    pool:    fullSyncPool,
    daemon:  fullSyncDaemon,
    single:  fullSyncSingle,
    multi:   fullSyncMulti)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
