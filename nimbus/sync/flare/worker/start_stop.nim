# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronicles,
  pkg/eth/[common, p2p],
  ../../protocol,
  ../worker_desc,
  "."/[staged, unproc]

when enableTicker:
  import ./start_stop/ticker

logScope:
  topics = "flare start/stop"

const extraTraceMessages = false
  ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

when enableTicker:
  proc tickerUpdater(ctx: FlareCtxRef): TickerFlareStatsUpdater =
    ## Legacy stuff, will be probably be superseded by `metrics`
    result = proc: auto =
      TickerFlareStats(
        base:         ctx.layout.base,
        least:        ctx.layout.least,
        final:        ctx.layout.final,
        beacon:       ctx.lhc.beacon.header.number,
        nStaged:      ctx.stagedChunks(),
        stagedTop:    ctx.stagedTop(),
        unprocTop:    ctx.unprocTop(),
        nUnprocessed: ctx.unprocTotal(),
        nUnprocFragm: ctx.unprocChunks(),
        reorg:        ctx.pool.nReorg)

proc updateBeaconHeaderCB(ctx: FlareCtxRef): SyncReqNewHeadCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  when extraTraceMessages:
    var count = 0
  result = proc(h: BlockHeader) {.gcsafe, raises: [].} =
    if ctx.lhc.beacon.header.number < h.number:
      when extraTraceMessages:
        if count mod 77 == 0: # reduce some noise
          trace "updateBeaconHeaderCB", blockNumber=("#" & $h.number), count
        count.inc
      ctx.lhc.beacon.header = h
      ctx.lhc.beacon.changed = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

when enableTicker:
  proc setupTicker*(ctx: FlareCtxRef) =
    ## Helper for `setup()`: Start ticker
    ctx.pool.ticker = TickerRef.init(ctx.tickerUpdater)

  proc destroyTicker*(ctx: FlareCtxRef) =
    ## Helper for `release()`
    ctx.pool.ticker.destroy()
    ctx.pool.ticker = TickerRef(nil)

else:
  template setupTicker*(ctx: FlareCtxRef) = discard
  template destroyTicker*(ctx: FlareCtxRef) = discard

# ---------

proc setupRpcMagic*(ctx: FlareCtxRef) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  ctx.chain.com.syncReqNewHead = ctx.updateBeaconHeaderCB

proc destroyRpcMagic*(ctx: FlareCtxRef) =
  ## Helper for `release()`
  ctx.chain.com.syncReqNewHead = SyncReqNewHeadCB(nil)

# ---------

proc startBuddy*(buddy: FlareBuddyRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and peer.state(protocol.eth).initialized:
    ctx.pool.nBuddies.inc # for metrics
    when enableTicker:
      ctx.pool.ticker.startBuddy()
    return true

proc stopBuddy*(buddy: FlareBuddyRef) =
  buddy.ctx.pool.nBuddies.dec # for metrics
  when enableTicker:
    buddy.ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
