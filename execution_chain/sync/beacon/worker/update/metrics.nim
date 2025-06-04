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
  ../../worker_desc,
  ../blocks_staged/staged_queue,
  ../headers_staged/staged_queue,
  ".."/[blocks_unproc, headers_unproc]

declareGauge nec_base, "" &
  "Max block number of imported finalised blocks"

declareGauge nec_execution_head, "" &
  "Block number of latest imported blocks"

declareGauge nec_sync_coupler, "" &
  "Lower limit block number for header chain to fetch"

declareGauge nec_sync_dangling, "" &
  "Least block number for header chain already fetched"

declareGauge nec_sync_last_block_imported, "" &
  "last block successfully imported/executed by FC module"

declareGauge nec_sync_head, "" &
  "Current sync target block number (if any)"

declareGauge nec_sync_consensus_head, "" &
  "Block number of sync scrum request block number "


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

declareGauge nec_sync_non_peers_connected, "" &
  "Number of currently connected peers less active worker instances"


template updateMetricsImpl(ctx: BeaconCtxRef) =
  metrics.set(nec_base, ctx.chain.baseNumber.int64)
  metrics.set(nec_execution_head, ctx.chain.latestNumber.int64)
  var coupler = ctx.headersUnprocTotalBottom()
  if high(int64).uint64 <= coupler:
    coupler = 0
  metrics.set(nec_sync_coupler, coupler.int64)
  metrics.set(nec_sync_dangling, ctx.hdrCache.antecedent.number.int64)
  metrics.set(nec_sync_last_block_imported, ctx.subState.top.int64)
  metrics.set(nec_sync_head, ctx.subState.head.int64)

  # Show last valid state.
  let consHeadNumber = ctx.hdrCache.latestConsHeadNumber
  if 0 < consHeadNumber:
    metrics.set(nec_sync_consensus_head, consHeadNumber.int64)

  metrics.set(nec_sync_header_lists_staged, ctx.headersStagedQueueLen())
  metrics.set(nec_sync_headers_unprocessed, ctx.headersUnprocTotal().int64)

  metrics.set(nec_sync_block_lists_staged, ctx.blocksStagedQueueLen())
  metrics.set(nec_sync_blocks_unprocessed, ctx.blocksUnprocTotal().int64)

  metrics.set(nec_sync_peers, ctx.pool.nBuddies)
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
