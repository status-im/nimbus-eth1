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
  stew/[interval_set, keyed_queue],
  "../.."/[common, db/select_backend],
  ".."/[handlers/eth, protocol, sync_desc, types],
  ./worker/[pivot, play, ticker],
  ./worker/com/com_error,
  ./worker/db/[snapdb_desc, snapdb_pivot],
  "."/[range_desc, worker_desc]

logScope:
  topics = "snap-worker"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template ignoreException(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    error "Exception at " & info & ":", name=($e.name), msg=(e.msg)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc disableWireServices(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Temporarily stop useless wire protocol services.
  ctx.ethWireCtx.txPoolEnabled = false

proc enableWireServices(ctx: SnapCtxRef) =
  ## Helper for `release()`
  ctx.ethWireCtx.txPoolEnabled = true

# --------------

proc enableTicker(ctx: SnapCtxRef; tickerOK: bool) =
  ## Helper for `setup()`: Log/status ticker
  if tickerOK:
    ctx.pool.ticker = TickerRef.init(ctx.pool.pivotTable.tickerStats(ctx))
  else:
    trace "Ticker is disabled"

proc disableTicker(ctx: SnapCtxRef) =
  ## Helper for `release()`
  if not ctx.pool.ticker.isNil:
    ctx.pool.ticker.stop()
    ctx.pool.ticker = nil

# --------------

proc enableRpcMagic(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  ctx.chain.com.syncReqNewHead = ctx.pivotUpdateBeaconHeaderCB

proc disableRpcMagic(ctx: SnapCtxRef) =
  ## Helper for `release()`
  ctx.chain.com.syncReqNewHead = nil

# --------------

proc detectSnapSyncRecovery(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Initiate snap sync recovery (if any)
  let rc = ctx.pool.snapDb.pivotRecoverDB()
  if rc.isOk:
    ctx.pool.recovery = SnapRecoveryRef(state: rc.value)
    ctx.daemon = true

    # Set up early initial pivot
    ctx.pool.pivotTable.reverseUpdate(ctx.pool.recovery.state.header, ctx)
    trace "Snap sync recovery started",
      checkpoint=(ctx.pool.pivotTable.topNumber.toStr & "(0)")
    if not ctx.pool.ticker.isNil:
      ctx.pool.ticker.startRecovery()

proc initSnapDb(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Initialise snap sync database layer
  ctx.pool.snapDb =
    if ctx.pool.dbBackend.isNil: SnapDbRef.init(ctx.chain.db.db)
    else: SnapDbRef.init(ctx.pool.dbBackend)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef; tickerOK: bool): bool =
  ## Global set up

  # For snap sync book keeping
  ctx.pool.coveredAccounts = NodeTagRangeSet.init()

  ctx.enableRpcMagic()          # Allow external pivot update via RPC
  ctx.disableWireServices()     # Stop unwanted public services
  ctx.pool.syncMode.playInit()  # Set up sync sub-mode specs.
  ctx.initSnapDb()              # Set database backend, subject to change
  ctx.detectSnapSyncRecovery()  # Check for recovery mode
  ctx.enableTicker(tickerOK)    # Start log/status ticker (if any)

  # Experimental, also used for debugging
  if ctx.exCtrlFile.isSome:
    warn "Snap sync accepts pivot block number or hash",
      syncCtrlFile=ctx.exCtrlFile.get
  true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.disableTicker()           # Stop log/status ticker (if any)
  ctx.enableWireServices()      # re-enable public services
  ctx.disableRpcMagic()         # Disable external pivot update via RPC


proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.snap) and
     peer.supports(protocol.eth) and
     peer.state(protocol.eth).initialized:
    buddy.only.errors = ComErrorStatsRef()
    if not ctx.pool.ticker.isNil:
      ctx.pool.ticker.startBuddy()
    return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  let ctx = buddy.ctx
  if not ctx.pool.ticker.isNil:
    ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# Public functions, sync handler multiplexers
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: SnapCtxRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runDaemon"):
    await ctx.playSyncSpecs.daemon(ctx)

proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runSingle"):
    await buddy.ctx.playSyncSpecs.single(buddy)

proc runPool*(buddy: SnapBuddyRef, last: bool; laps: int): bool =
  ## Sync processsing multiplexer
  ignoreException("runPool"):
    result = buddy.ctx.playSyncSpecs.pool(buddy,last,laps)

proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runMulti"):
    await buddy.ctx.playSyncSpecs.multi(buddy)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
