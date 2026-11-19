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
  ../../../../utils/simple_eta,
  ../worker_desc

declareGauge nec_sync_blocks_eta_secs, "" &
  "Estimated seconds until blocks import finished"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateEtaIdle*(ctx: BeaconCtxRef) =
  ctx.hdrCache.updateMetrics()

proc hdrEta*(ctx: BeaconCtxRef): Opt[Duration] =
  ctx.hdrCache.getEta()

proc blkEta*(ctx: BeaconCtxRef): Opt[Duration] =
  ctx.pool.blocksEta.eta()


proc blocksEtaInit*(ctx: BeaconCtxRef) =
  ## Initialise blocks import ETA.
  ctx.pool.blocksEta.init()
  metrics.set(nec_sync_blocks_eta_secs, 0f)

proc blocksEtaUpdate*(ctx: BeaconCtxRef) =
  ## Update ETA while system is in `blocks` state.
  let
    nAllBlocks = 1 + ctx.subState.headNum - ctx.hdrCache.antecedent.number
    # Note that `topNum` is at the last imported block, initialised
    # before importing as `antecedent.number-1`.
    nProcessed = 1 + ctx.subState.topNum - ctx.hdrCache.antecedent.number
  ctx.pool.blocksEta.apply nProcessed.float / nAllBlocks.float
  ctx.pool.blocksEta.eta().isErrOr:
    metrics.set(nec_sync_blocks_eta_secs, value.seconds)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
