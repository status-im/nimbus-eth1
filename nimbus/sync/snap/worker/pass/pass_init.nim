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
  "../../../.."/[common, db/select_backend],
  ../../../misc/ticker,
  ../../worker_desc,
  ../db/snapdb_desc,
  "."/[pass_full, pass_snap]

logScope:
  topics = "snap-init"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc setupPass(ctx: SnapCtxRef) =
  ## Set up sync mode specs table. This cannot be done at compile time.
  ctx.pool.syncMode.tab[SnapSyncMode] = passSnap()
  ctx.pool.syncMode.tab[FullSyncMode] = passFull()
  ctx.pool.syncMode.active = SnapSyncMode

proc releasePass(ctx: SnapCtxRef) =
  discard

# --------------

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

proc passInitSetup*(ctx: SnapCtxRef) =
  ## Global set up
  ctx.setupPass()               # Set up sync sub-mode specs.
  ctx.setupSnapDb()             # Set database backend, subject to change
  ctx.setupTicker()             # Start log/status ticker (if any)

  # Experimental, also used for debugging
  if ctx.exCtrlFile.isSome:
    warn "Snap sync accepts pivot block number or hash",
      syncCtrlFile=ctx.exCtrlFile.get

proc passInitRelease*(ctx: SnapCtxRef) =
  ## Global clean up
  ctx.releaseTicker()           # Stop log/status ticker (if any)
  ctx.releasePass()             # Shut down sync methods

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
