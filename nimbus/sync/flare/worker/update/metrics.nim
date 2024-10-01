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
  ".."/[db, blocks_staged, headers_staged]

declareGauge flare_beacon_block_number, "" &
  "Block number of latest known finalised header"

declareGauge flare_state_block_number, "" &
  "Max block number of imported/executed blocks"
  
declareGauge flare_base_block_number, "" &
  "Max block number initial header chain starting at genesis"

declareGauge flare_least_block_number, "" &
  "Starting/min block number for higher up headers chain"

declareGauge flare_final_block_number, "" &
  "Ending/max block number of higher up headers chain"

declareGauge flare_headers_staged_queue_len, "" &
  "Number of header list records staged for serialised processing"

declareGauge flare_headers_unprocessed, "" &
  "Number of block numbers ready to fetch and stage headers"

declareGauge flare_blocks_staged_queue_len, "" &
  "Number of block list records staged for importing"

declareGauge flare_blocks_unprocessed, "" &
  "Number of block numbers ready to fetch and stage block data"

declareGauge flare_number_of_buddies, "" &
  "Number of currently active worker instances"


template updateMetricsImpl*(ctx: FlareCtxRef) =
  metrics.set(flare_beacon_block_number, ctx.lhc.beacon.header.number.int64)

  metrics.set(flare_state_block_number, ctx.dbStateBlockNumber().int64)
  metrics.set(flare_base_block_number, ctx.layout.base.int64)
  metrics.set(flare_least_block_number, ctx.layout.least.int64)
  metrics.set(flare_final_block_number, ctx.layout.final.int64)

  metrics.set(flare_headers_staged_queue_len, ctx.headersStagedQueueLen())
  metrics.set(flare_headers_unprocessed,
              (ctx.headersUnprocTotal() + ctx.headersUnprocBorrowed()).int64)

  metrics.set(flare_blocks_staged_queue_len, ctx.blocksStagedQueueLen())
  metrics.set(flare_blocks_unprocessed,
              (ctx.blocksUnprocTotal() + ctx.blocksUnprocBorrowed()).int64)

  metrics.set(flare_number_of_buddies, ctx.pool.nBuddies)

# End
