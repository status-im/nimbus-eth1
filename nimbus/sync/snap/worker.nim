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
  ../misc/ticker,
  ./worker/pass,
  ./worker/get/get_error,
  ./worker/db/snapdb_desc,
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

proc setupTicker(ctx: SnapCtxRef) =
  let blindTicker: TickerSnapStatsUpdater = proc: TickerSnapStats =
    discard
  if ctx.pool.enableTicker:
    ctx.pool.ticker = TickerRef.init(blindTicker)

proc releaseTicker(ctx: SnapCtxRef) =
  ## Helper for `release()`
  ctx.pool.ticker.stop()
  ctx.pool.ticker = nil

# --------------

proc setupSnapDb(ctx: SnapCtxRef) =
  ## Helper for `setup()`: Initialise snap sync database layer
  ctx.pool.snapDb =
    if ctx.pool.dbBackend.isNil: SnapDbRef.init(ctx.chain.db.db)
    else: SnapDbRef.init(ctx.pool.dbBackend)

# ------------------------------------------------------------------------------
# Public start/stop and admin functions
# ------------------------------------------------------------------------------

proc setup*(ctx: SnapCtxRef): bool =
  ## Global set up
  ctx.passSetup()               # Set up sync sub-mode specs.
  ctx.setupSnapDb()             # Set database backend, subject to change
  ctx.setupTicker()             # Start log/status ticker (if any)

  # Experimental, also used for debugging
  if ctx.exCtrlFile.isSome:
    warn "Snap sync accepts pivot block number or hash",
      syncCtrlFile=ctx.exCtrlFile.get

  ignoreException("setup"):
    ctx.passActor.setup(ctx)
  true

proc release*(ctx: SnapCtxRef) =
  ## Global clean up
  ignoreException("release"):
    ctx.passActor.release(ctx)

  ctx.releaseTicker()           # Stop log/status ticker (if any)
  ctx.passRelease()             # Shut down sync methods


proc start*(buddy: SnapBuddyRef): bool =
  ## Initialise worker peer
  ignoreException("start"):
    if  buddy.ctx.passActor.start(buddy):
      buddy.only.errors = GetErrorStatsRef()
      return true

proc stop*(buddy: SnapBuddyRef) =
  ## Clean up this peer
  ignoreException("stop"):
    buddy.ctx.passActor.stop(buddy)

# ------------------------------------------------------------------------------
# Public functions, sync handler multiplexers
# ------------------------------------------------------------------------------

proc runDaemon*(ctx: SnapCtxRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runDaemon"):
    await ctx.passActor.daemon(ctx)

proc runSingle*(buddy: SnapBuddyRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runSingle"):
    await buddy.ctx.passActor.single(buddy)

proc runPool*(buddy: SnapBuddyRef, last: bool; laps: int): bool =
  ## Sync processsing multiplexer
  ignoreException("runPool"):
    result = buddy.ctx.passActor.pool(buddy,last,laps)

proc runMulti*(buddy: SnapBuddyRef) {.async.} =
  ## Sync processsing multiplexer
  ignoreException("runMulti"):
    await buddy.ctx.passActor.multi(buddy)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
