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
  pkg/metrics,
  ../../worker_desc,
  ".."/[blocks_staged, headers_staged]

declareGauge beacon_base, "" &
  "Max block number of finalised blocks"
  
declareGauge beacon_coupler, "" &
  "Max block number for header chain starting at genesis"

declareGauge beacon_dangling, "" &
  "Starting/min block number for higher up headers chain"

declareGauge beacon_final, "" &
  "Max number of finalised block in higher up headers chain"

declareGauge beacon_head, "" &
  "Ending/max block number of higher up headers chain"

declareGauge beacon_target, "" &
  "Block number of sync target (would be consensus header)"


declareGauge beacon_header_lists_staged, "" &
  "Number of header list records staged for serialised processing"

declareGauge beacon_headers_unprocessed, "" &
  "Number of block numbers ready to fetch and stage headers"

declareGauge beacon_block_lists_staged, "" &
  "Number of block list records staged for importing"

declareGauge beacon_blocks_unprocessed, "" &
  "Number of block numbers ready to fetch and stage block data"


declareGauge beacon_buddies, "" &
  "Number of currently active worker instances"


template updateMetricsImpl*(ctx: BeaconCtxRef) =
  metrics.set(beacon_base, ctx.chain.baseNumber().int64)
  metrics.set(beacon_coupler, ctx.layout.coupler.int64)
  metrics.set(beacon_dangling, ctx.layout.dangling.int64)
  metrics.set(beacon_final, ctx.layout.final.int64)
  metrics.set(beacon_head, ctx.layout.head.int64)
  metrics.set(beacon_target, ctx.target.consHead.number.int64)

  metrics.set(beacon_header_lists_staged, ctx.headersStagedQueueLen())
  metrics.set(beacon_headers_unprocessed,
              (ctx.headersUnprocTotal() + ctx.headersUnprocBorrowed()).int64)

  metrics.set(beacon_block_lists_staged, ctx.blocksStagedQueueLen())
  metrics.set(beacon_blocks_unprocessed,
              (ctx.blocksUnprocTotal() + ctx.blocksUnprocBorrowed()).int64)

  metrics.set(beacon_buddies, ctx.pool.nBuddies)

# End
