# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ../headers/headers_unproc,
  ../worker_desc

declareGauge nec_sync_eta_secs, "" &
  "Seconds until current consensus head is reached"

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
# Public functions, metrics management (includes ETA guess)
# ------------------------------------------------------------------------------

proc updateEtaInit*(ctx: BeaconCtxRef) =
  ## Initialise ETA with some high guess values so the ETA is supposed to
  ## go down over time.
  ##
  ctx.pool.syncEta.reset
  ctx.pool.syncEta.headerTime = etaHeaderTimeDefault
  ctx.pool.syncEta.blockTime = etaBlockTimeDefault
  metrics.set(nec_sync_eta_secs, -1)

# --------------

proc updateEtaIdle*(ctx: BeaconCtxRef) =
  ## Metrics update while system state is idle so it can be run on a ticker.
  ## Othewise, ETA updates are done with the syncer state handler.
  ##
  if ctx.pool.syncState == SyncState.idle and
     low(Moment) < ctx.pool.syncEta.lastUpdate and
     ctx.pool.syncEta.lastUpdate + etaIdleMaxDensity <= Moment.now():

    let toDo = dist(ctx.chain.latestNumber, ctx.hdrCache.latestConsHeadNumber)
    if toDo == 0:
      # No sync request at the moment
      ctx.pool.syncEta.inSync = true
      metrics.set(nec_sync_eta_secs, 0)
      ctx.hdrCache.updateMetrics()
    else:
      # Caclculate the duration to process all the headers and all
      # blocks, i.e
      # * headers and blocks to be stored for the rest until known target
      let bothTime = ctx.pool.syncEta.headerTime + ctx.pool.syncEta.blockTime
      ctx.setEtaAndMetrics(bothTime * toDo.float)
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
          restTime = ctx.pool.syncEta.headerTime + ctx.pool.syncEta.blockTime

          blksNs = ctx.pool.syncEta.blockTime * blocksToDo.float
          restNs = restTime * restToDo.float

        ctx.setEtaAndMetrics(blksNs + restNs)


proc updateEtaHeaders*(ctx: BeaconCtxRef) =
  ## Eta and metrics while system is in `headers` state
  ##
  if low(Moment) < ctx.pool.syncEta.lastUpdate:
    # There is a minimum time span beween two samples to take.
    let
      now = Moment.now()
      headersToDo = ctx.headersUnprocTotal().float
    if ctx.pool.syncEta.lastUpdate + etaHeaderMaxDensity <= now or
       headersToDo < 2:

      let nProcessed = dist(ctx.hdrCache.antecedent.number,ctx.subState.headNum)
      if nFetchHeadersRequest < nProcessed or
         (0 < nProcessed and headersToDo <= nFetchHeadersRequest):

        let elapsed = now - ctx.pool.subState.stateSince
        ctx.pool.syncEta.headerTime =
          elapsed.nanoseconds.float / nProcessed.float

        # Caclculate the duration to process all the headers and all
        # blocks, i.e
        # * headers to be stored for this sprint
        # * blocks to be stored for this sprint
        # * headers and blocks to be stored for the rest until known target
        let
          blocksToDo = dist(ctx.chain.baseNumber, ctx.subState.headNum)
          restToDo = dist(ctx.subState.headNum,
                          ctx.hdrCache.latestConsHeadNumber)
          restTime = ctx.pool.syncEta.headerTime + ctx.pool.syncEta.blockTime

          hdrsNs = ctx.pool.syncEta.headerTime * headersToDo.float
          blksNs = ctx.pool.syncEta.blockTime * blocksToDo.float
          restNs = restTime * restToDo.float

        ctx.setEtaAndMetrics(hdrsNs + blksNs + restNs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
