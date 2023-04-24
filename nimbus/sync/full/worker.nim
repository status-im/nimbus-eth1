# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  chronicles,
  chronos,
  eth/p2p,
  ".."/[protocol, sync_desc],
  ../misc/[best_pivot, block_queue, sync_ctrl, ticker],
  ./worker_desc

logScope:
  topics = "full-buddy"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

  FirstPivotSeenTimeout = 3.minutes
    ## Turn on relaxed pivot negotiation after some waiting time when there
    ## was a `peer` seen but was rejected. This covers a rare event. Typically
    ## useless peers do not appear ready for negotiation.

  FirstPivotAcceptedTimeout = 50.seconds
    ## Turn on relaxed pivot negotiation after some waiting time when there
    ## was a `peer` accepted but no second one yet.

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


proc tickerUpdater(ctx: FullCtxRef): TickerFullStatsUpdater =
  result = proc: auto =
    var stats: BlockQueueStats
    ctx.pool.bCtx.blockQueueStats(stats)

    let suspended =
      0 < ctx.pool.suspendAt and ctx.pool.suspendAt < stats.topAccepted

    TickerFullStats(
      topPersistent:   stats.topAccepted,
      nextStaged:      stats.nextStaged,
      nextUnprocessed: stats.nextUnprocessed,
      nStagedQueue:    stats.nStagedQueue,
      suspended:       suspended,
      reOrg:           stats.reOrg)


proc processStaged(buddy: FullBuddyRef): bool =
  ## Fetch a work item from the `staged` queue an process it to be
  ## stored on the persistent block chain.
  let
    ctx {.used.} = buddy.ctx
    peer = buddy.peer
    chainDb = buddy.ctx.chain.db
    chain = buddy.ctx.chain
    bq = buddy.only.bQueue

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
    error "Storing persistent blocks failed", peer, range=($wi.blocks),
      error = $e.name, msg = e.msg

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


proc suspendDownload(buddy: FullBuddyRef): bool =
  ## Check whether downloading should be suspended
  let ctx = buddy.ctx
  if ctx.exCtrlFile.isSome:
    let rc = ctx.exCtrlFile.syncCtrlBlockNumberFromFile
    if rc.isOk:
      ctx.pool.suspendAt = rc.value
    if 0 < ctx.pool.suspendAt:
      return ctx.pool.suspendAt < buddy.only.bQueue.topAccepted

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: FullCtxRef; tickerOK: bool): bool =
  ## Global set up
  ctx.pool.pivot = BestPivotCtxRef.init(ctx.pool.rng)
  let rc = ctx.topUsedNumber(backBlocks = 0)
  if rc.isErr:
    ctx.pool.bCtx = BlockQueueCtxRef.init()
    return false
  ctx.pool.bCtx = BlockQueueCtxRef.init(rc.value + 1)
  if tickerOK:
    ctx.pool.ticker = TickerRef.init(ctx.tickerUpdater)
  else:
    debug "Ticker is disabled"

  if ctx.exCtrlFile.isSome:
    warn "Full sync accepts suspension request block number",
      syncCtrlFile=ctx.exCtrlFile.get
  true

proc release*(ctx: FullCtxRef) =
  ## Global clean up
  ctx.pool.pivot = nil
  if not ctx.pool.ticker.isNil:
    ctx.pool.ticker.stop()

proc start*(buddy: FullBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    if not ctx.pool.ticker.isNil:
      ctx.pool.ticker.startBuddy()
    buddy.only.pivot =
      BestPivotWorkerRef.init(ctx.pool.pivot, buddy.ctrl, buddy.peer)
    buddy.only.bQueue = BlockQueueWorkerRef.init(
      ctx.pool.bCtx, buddy.ctrl, peer)
    return true

proc stop*(buddy: FullBuddyRef) =
  ## Clean up this peer
  buddy.ctrl.stopped = true
  buddy.only.pivot.clear()
  if not buddy.ctx.pool.ticker.isNil:
     buddy.ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: FullCtxRef) {.async.} =
  ## Global background job that will be re-started as long as the variable
  ## `ctx.daemon` is set `true`. If that job was stopped due to re-setting
  ## `ctx.daemon` to `false`, it will be restarted next after it was reset
  ## as `true` not before there is some activity on the `runPool()`,
  ## `runSingle()`, or `runMulti()` functions.
  ##
  case ctx.pool.pivotState:
  of FirstPivotSeen:
    let elapsed = Moment.now() - ctx.pool.pivotStamp
    if FirstPivotSeenTimeout < elapsed:
      # Switch to single peer pivot negotiation
      ctx.pool.pivot.pivotRelaxedMode(enable = true)

      # Currently no need for other monitor tasks
      ctx.daemon = false

      when extraTraceMessages:
        trace "First seen pivot timeout", elapsed,
          pivotState=ctx.pool.pivotState
      return
    # Otherwise delay for some time

  of FirstPivotAccepted:
    let elapsed = Moment.now() - ctx.pool.pivotStamp
    if FirstPivotAcceptedTimeout < elapsed:
      # Switch to single peer pivot negotiation
      ctx.pool.pivot.pivotRelaxedMode(enable = true)

      # Use currents pivot next time `runSingle()` is visited. This bent is
      # necessary as there must be a peer initialising and syncing blocks. But
      # this daemon has no peer assigned.
      ctx.pool.pivotState = FirstPivotUseRegardless

      # Currently no need for other monitor tasks
      ctx.daemon = false

      when extraTraceMessages:
        trace "First accepted pivot timeout", elapsed,
          pivotState=ctx.pool.pivotState
      return
    # Otherwise delay for some time

  else:
    # Currently no need for other monitior tasks
    ctx.daemon = false
    return

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.) Larger waiting time cleans up logging.
  await sleepAsync 300.milliseconds


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
    peer {.used.} = buddy.peer
    bq = buddy.only.bQueue
    pv = buddy.only.pivot

  when extraTraceMessages:
    trace "Single mode begin", peer, pivotState=ctx.pool.pivotState

  case ctx.pool.pivotState:
    of PivotStateInitial:
      # Set initial state on first encounter
      ctx.pool.pivotState = FirstPivotSeen
      ctx.pool.pivotStamp = Moment.now()
      ctx.daemon = true # Start monitor

    of FirstPivotSeen, FirstPivotAccepted:
      discard

    of FirstPivotUseRegardless:
      # Magic case when we accept anything under the sun
      let rc = pv.pivotHeader(relaxedMode=true)
      if rc.isOK:
        # Update/activate `bestNumber` from the pivot header
        bq.bestNumber = some(rc.value.blockNumber)
        ctx.pool.pivotState = PivotRunMode
        buddy.ctrl.multiOk = true
        trace "Single pivot accepted", peer, pivot=('#' & $bq.bestNumber.get)
        return # stop logging, otherwise unconditional return for this case

      when extraTraceMessages:
        trace "Single mode stopped", peer, pivotState=ctx.pool.pivotState
      return # unconditional return for this case

    of PivotRunMode:
      # Sync backtrack runs in single mode
      if bq.blockQueueBacktrackOk:
        let rc = await bq.blockQueueBacktrackWorker()
        if rc.isOk:
          # Update persistent database (may reset `multiOk`)
          buddy.ctrl.multiOk = true
          while buddy.processStaged() and not buddy.ctrl.stopped:
            # Allow thread switch as `persistBlocks()` might be slow
            await sleepAsync(10.milliseconds)
          when extraTraceMessages:
            trace "Single backtrack mode done", peer
          return

        buddy.ctrl.zombie = true

        when extraTraceMessages:
          trace "Single backtrack mode stopped", peer
        return
    # End case()

  # Negotiate in order to derive the pivot header from this `peer`. This code
  # location here is reached when there was no compelling reason for the
  # `case()` handler to process and `return`.
  if await pv.pivotNegotiate(buddy.only.bQueue.bestNumber):
    # Update/activate `bestNumber` from the pivot header
    bq.bestNumber = some(pv.pivotHeader.value.blockNumber)
    ctx.pool.pivotState = PivotRunMode
    buddy.ctrl.multiOk = true
    trace "Pivot accepted", peer, pivot=('#' & $bq.bestNumber.get)
    return

  if buddy.ctrl.stopped:
    when extraTraceMessages:
      trace "Single mode stopped", peer, pivotState=ctx.pool.pivotState
    return # done with this buddy

  var napping = 2.seconds
  case ctx.pool.pivotState:
  of FirstPivotSeen:
    # Possible state transition
    if pv.pivotHeader(relaxedMode=true).isOk:
      ctx.pool.pivotState = FirstPivotAccepted
      ctx.pool.pivotStamp = Moment.now()
    napping = 300.milliseconds
  of FirstPivotAccepted:
    napping = 300.milliseconds
  else:
    discard

  when extraTraceMessages:
    trace "Single mode end", peer, pivotState=ctx.pool.pivotState, napping

  # Without waiting, this function repeats every 50ms (as set with the constant
  # `sync_sched.execLoopTimeElapsedMin`.)
  await sleepAsync napping


proc runPool*(buddy: FullBuddyRef; last: bool; laps: int): bool =
  ## Once started, the function `runPool()` is called for all worker peers in
  ## sequence as the body of an iteration as long as the function returns
  ## `false`. There will be no other worker peer functions activated
  ## simultaneously.
  ##
  ## This procedure is started if the global flag `buddy.ctx.poolMode` is set
  ## `true` (default is `false`.) It will be automatically reset before the
  ## the loop starts. Re-setting it again results in repeating the loop. The
  ## argument `lap` (starting with `0`) indicated the currend lap of the
  ## repeated loops.
  ##
  ## The argument `last` is set `true` if the last entry is reached.
  ##
  ## Note that this function does not run in `async` mode.
  ##
  # Mind the gap, fill in if necessary (function is peer independent)
  buddy.only.bQueue.blockQueueGrout()
  true # Stop after running once regardless of peer

proc runMulti*(buddy: FullBuddyRef) {.async.} =
  ## This peer worker is invoked if the `buddy.ctrl.multiOk` flag is set
  ## `true` which is typically done after finishing `runSingle()`. This
  ## instance can be simultaneously active for all peer workers.
  ##
  let
    ctx = buddy.ctx
    bq = buddy.only.bQueue

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
      return

  # Update persistent database
  while buddy.processStaged() and not buddy.ctrl.stopped:
    # Allow thread switch as `persistBlocks()` might be slow
    await sleepAsync(10.milliseconds)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
