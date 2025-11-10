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
  pkg/[chronos,  metrics],
  ../../../../networking/p2p,
  ../worker_desc

declareGauge nec_base, "" &
  "Max block number of imported finalised blocks"

declareGauge nec_execution_head, "" &
  "Block number of latest imported blocks"

declareGauge nec_sync_non_peers_connected, "" &
  "Number of currently connected peers less active worker instances"


template updateMetricsImpl(ctx: BeaconCtxRef) =

  # Legacy/foster entries, need to me moved to `FC` module.
  metrics.set(nec_base, ctx.chain.baseNumber.int64)
  metrics.set(nec_execution_head, ctx.chain.latestNumber.int64)

  # Convenience entry, no need to be exact here.
  metrics.set(nec_sync_non_peers_connected,
              # nBuddies might not be commited/updated yet
              max(0,ctx.node.peerPool.connectedNodes.len - ctx.pool.nBuddies))

# ---------------

proc updateMetrics*(ctx: BeaconCtxRef; force = false) =
  let now = Moment.now()
  if ctx.pool.nextMetricsUpdate < now:
    ctx.updateMetricsImpl()
    ctx.pool.nextMetricsUpdate = now + metricsUpdateInterval

# End
