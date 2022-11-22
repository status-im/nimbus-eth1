# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/[options],
  chronicles,
  chronos,
  eth/[common, p2p],
  ".."/[protocol, sync_desc],
  ../misc/[best_pivot, block_queue],
  ./ticker

{.push raises:[Defect].}

logScope:
  topics = "full-sync"

type
  BuddyData* = object
    ## Local descriptor data extension
    pivot: BestPivotWorkerRef       ## Local pivot worker descriptor
    bQueue: BlockQueueWorkerRef     ## Block queue worker
    bestNumber: Option[BlockNumber] ## Largest block number reported

  CtxData* = object
    ## Globally shared data extension
    rng*: ref HmacDrbgContext       ## Random generator, pre-initialised
    pivot: BestPivotCtxRef          ## Global pivot descriptor
    bCtx: BlockQueueCtxRef          ## Global block queue descriptor
    ticker: TickerRef               ## Logger ticker

  FullBuddyRef* = ##\
    ## Extended worker peer descriptor
    BuddyRef[CtxData,BuddyData]

  FullCtxRef* = ##\
    ## Extended global descriptor
    CtxRef[CtxData]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc pp(n: BlockNumber): string =
  ## Dedicated pretty printer (`$` is defined elsewhere using `UInt256`)
  if n == high(BlockNumber): "high" else:"#" & $n

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc topUsedNumber(
    ctx: FullCtxRef;
    backBlocks = maxHeadersFetch;
      ): Result[BlockNumber,void] =
  var
    top = 0.toBlockNumber
  try:
    let
      bestNumber = ctx.chain.db.getCanonicalHead().blockNumber
      nBackBlocks = backBlocks.toBlockNumber
    # Initialise before best block number
    if nBackBlocks < bestNumber:
      top = bestNumber - nBackBlocks
  except CatchableError as e:
    error "Best block header problem", backBlocks, error=($e.name), msg=e.msg
    return err()

  ok(top)


proc tickerUpdater(ctx: FullCtxRef): TickerStatsUpdater =
  result = proc: TickerStats =
    var stats: BlockQueueStats
    ctx.data.bCtx.blockQueueStats(stats)

    TickerStats(
      topPersistent:   stats.topAccepted,
      nextStaged:      stats.nextStaged,
      nextUnprocessed: stats.nextUnprocessed,
      nStagedQueue:    stats.nStagedQueue,
      reOrg:           stats.reOrg)


proc processStaged(buddy: FullBuddyRef): bool =
  ## Fetch a work item from the `staged` queue an process it to be
  ## stored on the persistent block chain.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    chainDb = buddy.ctx.chain.db
    chain = buddy.ctx.chain
    bq = buddy.data.bQueue

    # Get a work item, a list of headers + bodies
    wi = block:
      let rc = bq.blockQueueFetchStaged()
      if rc.isErr:
        return false
      rc.value

    startNumber = wi.headers[0].blockNumber

  # Store in persistent database
  try:
    if chain.persistBlocks(wi.headers, wi.bodies) == ValidationResult.OK:
      bq.blockQueueAccept(wi)
      return true
  except CatchableError as e:
    error "Storing persistent blocks failed", peer, range=($wi.blocks),
      error = $e.name, msg = e.msg
  except Defect as e:
    # Pass through
    raise e
  except Exception as e:
    # Notorious case where the `Chain` reference applied to
    # `persistBlocks()` has the compiler traced a possible `Exception`
    # (i.e. `ctx.chain` could be uninitialised.)
    error "Exception while storing persistent blocks", peer,
      range=($wi.blocks), error=($e.name), msg=e.msg
    raise (ref Defect)(msg: $e.name & ": " & e.msg)

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
    error "Failed to access parent blocks", peer,
      blockNumber=wi.headers[0].blockNumber.pp, error=($e.name), msg=e.msg

  # Parent block header problem, so we might be in the middle of a re-org.
  # Set single mode backtrack following the offending parent hash.
  bq.blockQueueBacktrackFrom(wi)
  buddy.ctrl.multiOk = false

  if wi.topHash.isNone:
    # Assuming that currently staged entries are on the wrong branch
    bq.blockQueueRecycleStaged()
    notice "Starting chain re-org backtrack work item", peer, range=($wi.blocks)
  else:
    # Leave that block range in the staged list
    trace "Resuming chain re-org backtrack work item", peer, range=($wi.blocks)
    discard

  return false

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: FullCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.data.pivot = BestPivotCtxRef.init(ctx.data.rng)
  if tickerOK:
    ctx.data.ticker = TickerRef.init(ctx.tickerUpdater)
  else:
    debug "Ticker is disabled"
  let rc = ctx.topUsedNumber(backBlocks = 0)
  if rc.isErr:
    ctx.data.bCtx = BlockQueueCtxRef.init()
    return false
  ctx.data.bCtx = BlockQueueCtxRef.init(rc.value + 1)
  true

proc release*(ctx: FullCtxRef) =
  ## Global clean up
  ctx.data.pivot = nil
  if not ctx.data.ticker.isNil:
    ctx.data.ticker.stop()

proc start*(buddy: FullBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    if not ctx.data.ticker.isNil:
      ctx.data.ticker.startBuddy()
    buddy.data.pivot =
      BestPivotWorkerRef.init(ctx.data.pivot, buddy.ctrl, buddy.peer)
    buddy.data.bQueue = BlockQueueWorkerRef.init(
      ctx.data.bCtx, buddy.ctrl, peer)
    return true

proc stop*(buddy: FullBuddyRef) =
  ## Clean up this peer
  buddy.ctrl.stopped = true
  buddy.data.pivot.clear()
  if not buddy.ctx.data.ticker.isNil:
     buddy.ctx.data.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runSingle*(buddy: FullBuddyRef) {.async.} =
  ## This peer worker is invoked if the peer-local flag `buddy.ctrl.multiOk`
  ## is set `false` which is the default mode. This flag is updated by the
  ## worker when deemed appropriate.
  ## * For all workers, there can be only one `runSingle()` function active
  ##   simultaneously for all worker peers.
  ## * There will be no `runMulti()` function active for the same worker peer
  ##   simultaneously
  ## * There will be no `runPool()` iterator active simultaneously.
  ##
  ## Note that this function runs in `async` mode.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer
    bq = buddy.data.bQueue

  if bq.blockQueueBacktrackOk:
    let rc = await bq.blockQueueBacktrackWorker()
    if rc.isOk:

      # Update persistent database (may reset `multiOk`)
      buddy.ctrl.multiOk = true
      while buddy.processStaged() and not buddy.ctrl.stopped:
        # Allow thread switch as `persistBlocks()` might be slow
        await sleepAsync(10.milliseconds)
      return

    buddy.ctrl.zombie = true

  # Initialise/re-initialise this worker
  elif await buddy.data.pivot.pivotNegotiate(buddy.data.bestNumber):
    buddy.ctrl.multiOk = true
    # Update/activate `bestNumber` for local use
    buddy.data.bestNumber =
      some(buddy.data.pivot.pivotHeader.value.blockNumber)

  elif not buddy.ctrl.stopped:
    await sleepAsync(2.seconds)


proc runPool*(buddy: FullBuddyRef; last: bool) =
  ## Ocne started, the function `runPool()` is called for all worker peers in
  ## a row (as the body of an iteration.) There will be no other worker peer
  ## functions activated simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It is the responsibility of the `runPool()`
  ## instance to reset the flag `buddy.ctx.poolMode`, typically at the first
  ## peer instance.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  let
    ctx = buddy.ctx
    bq = buddy.data.bQueue
  if ctx.poolMode:
    # Mind the gap, fill in if necessary
    bq.blockQueueGrout()
    ctx.poolMode = false


proc runMulti*(buddy: FullBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  # Fetch work item
  let
    ctx = buddy.ctx
    bq = buddy.data.bQueue
    rc = await bq.blockQueueWorker()
  if rc.isErr:
    if rc.error == StagedQueueOverflow:
      # Mind the gap: Turn on pool mode if there are too may staged items.
      buddy.ctx.poolMode = true
    else:
      return

  # Update persistent database
  while buddy.processStaged() and not buddy.ctrl.stopped:
    # Allow thread switch as `persistBlocks()` might be slow
    await sleepAsync(10.milliseconds)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
