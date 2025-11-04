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
  # Update some metrics
  ctx.hdrCache.updateMetrics()

  if ctx.pool.syncState == SyncState.idle and
     ctx.chain.latestNumber <= ctx.hdrCache.latestConsHeadNumber and
     ctx.pool.syncEta.lastUpdate + etaIdleMaxDensity <= Moment.now():

    # Caclculate the duration to process all the headers and all blocks, i.e
    # * headers and blocks to be stored for the rest until known target
    let
      restToDo = ctx.hdrCache.latestConsHeadNumber - ctx.chain.latestNumber
      restTime = ctx.pool.syncEta.headerTime + ctx.pool.syncEta.blockTime

    ctx.setEtaAndMetrics(restTime * restToDo.float)


proc updateEtaBlocks*(ctx: BeaconCtxRef) =
  ## Update ETA while system is in `blocks` state.
  ##
  # Update some metrics
  ctx.hdrCache.updateMetrics()

  if low(Moment) < ctx.pool.syncEta.lastUpdate:
    # There is a minimum time span beween two samples to take.
    let
      now = Moment.now()
      blocksToDo = ctx.subState.head - ctx.subState.top
    if ctx.pool.syncEta.lastUpdate + etaBlockMaxDensity <= now or
       blocksToDo < 2:

      # Make certain to cover more than one successful fetch efforts unless
      # there are not many items to fetch.
      let nProcessed = ctx.subState.top - ctx.hdrCache.antecedent.number

      if nFetchBodiesRequest < nProcessed or
         blocksToDo <= nFetchBodiesRequest:

        let elapsed = now - ctx.pool.subState.stateSince
        ctx.pool.syncEta.blockTime =
          elapsed.nanoseconds.float / nProcessed.float

        # Caclculate the duration to process all the headers and all
        # blocks, i.e
        # * blocks to be stored for this sprint
        # * headers and blocks to be stored for the rest until known target
        let
          restToDo = ctx.hdrCache.latestConsHeadNumber - ctx.subState.head
          restTime = ctx.pool.syncEta.headerTime + ctx.pool.syncEta.blockTime

          blksNs = ctx.pool.syncEta.blockTime * blocksToDo.float
          restNs = restTime * restToDo.float

        ctx.setEtaAndMetrics(blksNs + restNs)


proc updateEtaHeaders*(ctx: BeaconCtxRef) =
  ## Eta and metrics while system is in `headers` state
  ##
  # Update some metrics
  ctx.hdrCache.updateMetrics()

  if low(Moment) < ctx.pool.syncEta.lastUpdate:
    # There is a minimum time span beween two samples to take.
    let
      now = Moment.now()
      headersToDo = ctx.headersUnprocTotal().float
    if ctx.pool.syncEta.lastUpdate + etaHeaderMaxDensity <= now or
       headersToDo < 2:

      let nProcessed = ctx.subState.head - ctx.subState.top

      if nFetchHeadersRequest < nProcessed or
         headersToDo <= nFetchHeadersRequest:

        let elapsed = now - ctx.pool.subState.stateSince

        ctx.pool.syncEta.headerTime =
          elapsed.nanoseconds.float / nProcessed.float

        # Caclculate the duration to process all the headers and all
        # blocks, i.e
        # * headers to be stored for this sprint
        # * blocks to be stored for this sprint
        # * headers and blocks to be stored for the rest until known target
        let
          blocksToDo = ctx.subState.head - ctx.chain.baseNumber
          restToDo = ctx.hdrCache.latestConsHeadNumber - ctx.subState.head
          restTime = ctx.pool.syncEta.headerTime + ctx.pool.syncEta.blockTime

          hdrsNs = ctx.pool.syncEta.headerTime * headersToDo.float
          blksNs = ctx.pool.syncEta.blockTime * blocksToDo.float
          restNs = restTime * restToDo.float

        ctx.setEtaAndMetrics(hdrsNs + blksNs + restNs)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
