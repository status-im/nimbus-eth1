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
  ../../../../core/chain,
  ../../worker_desc,
  ../blocks_staged/staged_queue,
  ../headers_staged/staged_queue,
  ".."/[blocks_unproc, headers_unproc]

declareGauge nec_base, "" &
  "Max block number of imported finalised blocks"

declareGauge nec_execution_head, "" &
  "Block number of latest imported blocks"
  
declareGauge nec_sync_coupler, "" &
  "Max block number for header chain starting at genesis"

declareGauge nec_sync_dangling, "" &
  "Starting/min block number for higher up headers chain"

declareGauge nec_sync_head, "" &
  "Ending/max block number of higher up headers chain"

declareGauge nec_consensus_head, "" &
  "Block number of sync target (would be consensus header)"


declareGauge nec_sync_header_lists_staged, "" &
  "Number of header list records staged for serialised processing"

declareGauge nec_sync_headers_unprocessed, "" &
  "Number of block numbers ready to fetch and stage headers"

declareGauge nec_sync_block_lists_staged, "" &
  "Number of block list records staged for importing"

declareGauge nec_sync_blocks_unprocessed, "" &
  "Number of block numbers ready to fetch and stage block data"


declareGauge nec_sync_peers, "" &
  "Number of currently active worker instances"


template updateMetricsImpl(ctx: BeaconCtxRef) =
  metrics.set(nec_base, ctx.chain.baseNumber().int64)
  metrics.set(nec_execution_head, ctx.chain.latestNumber().int64)
  metrics.set(nec_sync_coupler, ctx.layout.coupler.int64)
  metrics.set(nec_sync_dangling, ctx.layout.dangling.int64)
  metrics.set(nec_sync_head, ctx.layout.head.int64)

  # Show last valid state.
  if 0 < ctx.target.consHead.number:
    metrics.set(nec_consensus_head, ctx.target.consHead.number.int64)

  metrics.set(nec_sync_header_lists_staged, ctx.headersStagedQueueLen())
  metrics.set(nec_sync_headers_unprocessed,
              (ctx.headersUnprocTotal() + ctx.headersUnprocBorrowed()).int64)

  metrics.set(nec_sync_block_lists_staged, ctx.blocksStagedQueueLen())
  metrics.set(nec_sync_blocks_unprocessed,
              (ctx.blocksUnprocTotal() + ctx.blocksUnprocBorrowed()).int64)

  metrics.set(nec_sync_peers, ctx.pool.nBuddies)

# ---------------

proc updateMetrics*(ctx: BeaconCtxRef; force = false) =
  let now = Moment.now()
  if ctx.pool.nextUpdate < now or force:
    ctx.updateMetricsImpl()
    ctx.pool.nextUpdate = now + metricsUpdateInterval

# End
