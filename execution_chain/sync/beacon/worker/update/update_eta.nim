# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[chronos, metrics],
  ../worker_desc

declareGauge nec_sync_eta_secs, "" &
  "Estimated seconds until current consensus head is reached"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc setEtaAndMetrics(ctx: BeaconCtxRef; w: float) =
  ctx.pool.syncEta.add w
  if low(Moment) < ctx.pool.syncEta.lastUpdate:
    metrics.set(nec_sync_eta_secs, seconds ctx.pool.syncEta.avg)
  ctx.hdrCache.updateMetrics()

proc dist(a, b: BlockNumber): uint64 =
  ## Distrance from a to b, i.e. `max(0, b.int - a-int).uint`
  if b < a: 0 else: b - a

# ------------------------------------------------------------------------------
# Public functions, metrics management (includes ETA)
# ------------------------------------------------------------------------------

proc updateEtaInit*(ctx: BeaconCtxRef) =
  ## Initialise ETA with some high guess values so the ETA is supposed to
  ## go down over time.
  ##
  ctx.pool.syncEta.reset
  ctx.pool.syncEta.blockTime = etaBlockTimeDefault
  if ctx.pool.standByMode == BeaconServerMode.none:
    metrics.set(nec_sync_eta_secs, -1)              # waiting for data
  else:
    metrics.set(nec_sync_eta_secs, 0f)              # currently all done

# --------------

proc updateEtaIdle*(ctx: BeaconCtxRef) =
  ## Metrics update while system state is idle so it can be run on a ticker.
  ## Othewise, ETA updates are done with the syncer state handler.
  ##
  if ctx.pool.standByMode != BeaconServerMode.none:
    metrics.set(nec_sync_eta_secs, 0f)              # currently all done

  elif ctx.pool.syncState == BeaconState.idle and
     low(Moment) < ctx.pool.syncEta.lastUpdate and
     ctx.pool.syncEta.lastUpdate + etaIdleMaxDensity <= Moment.now():

    let toDo = dist(ctx.chain.latestNumber, ctx.hdrCache.latestConsHeadNumber)
    if toDo == 0:
      # No sync request at the moment
      ctx.pool.syncEta.inSync = true
      metrics.set(nec_sync_eta_secs, 0)
      ctx.hdrCache.updateMetrics()
    else:
      ctx.setEtaAndMetrics( ctx.pool.syncEta.blockTime * toDo.float)
      ctx.pool.syncEta.inSync = false


proc updateEtaBlocks*(ctx: BeaconCtxRef) =
  ## Update ETA while system is in `blocks` state.
  ##
  if low(Moment) < ctx.pool.syncEta.lastUpdate:
    # There is a minimum time span beween two samples to take.
    let
      now = Moment.now()
      blocksToDo = ctx.subState.headNum - ctx.subState.topNum
    if ctx.pool.syncEta.lastUpdate + etaBlockMaxDensity <= now or
       blocksToDo < 2:

      # Make certain to cover more than one successful fetch efforts unless
      # there are not many items to fetch.
      let nProcessed = dist(ctx.hdrCache.antecedent.number, ctx.subState.topNum)
      if nFetchBodiesRequest < nProcessed or
         (0 < nProcessed and blocksToDo <= nFetchBodiesRequest):

        let elapsed = now - ctx.pool.subState.stateSince
        ctx.pool.syncEta.blockTime =
          elapsed.nanoseconds.float / nProcessed.float

        # Caclculate the duration to process all the headers and all
        # blocks, i.e
        # * blocks to be stored for this sprint
        # * headers and blocks to be stored for the rest until known target
        let
          restToDo = dist(ctx.subState.headNum,
                          ctx.hdrCache.latestConsHeadNumber)

          blksNs = ctx.pool.syncEta.blockTime * blocksToDo.float

        ctx.setEtaAndMetrics(blksNs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
