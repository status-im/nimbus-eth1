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


declareGauge beacon_base, "" &
  "Max block number of imported/executed blocks"
  
declareGauge beacon_coupler, "" &
  "Max block number for header chain starting at genesis"

declareGauge beacon_least_block_number, "" &
  "Starting/min block number for higher up headers chain"

declareGauge beacon_end, "" &
  "Ending/max block number of higher up headers chain"

declareGauge beacon_beacon_block_number, "" &
  "Block number of latest known finalised header"


declareGauge beacon_headers_staged_queue_len, "" &
  "Number of header list records staged for serialised processing"

declareGauge beacon_headers_unprocessed, "" &
  "Number of block numbers ready to fetch and stage headers"

declareGauge beacon_blocks_staged_queue_len, "" &
  "Number of block list records staged for importing"

declareGauge beacon_blocks_unprocessed, "" &
  "Number of block numbers ready to fetch and stage block data"


declareGauge beacon_number_of_buddies, "" &
  "Number of currently active worker instances"


template updateMetricsImpl*(ctx: BeaconCtxRef) =
  metrics.set(beacon_base, ctx.dbStateBlockNumber().int64)
  metrics.set(beacon_coupler, ctx.layout.coupler.int64)
  metrics.set(beacon_least_block_number, ctx.layout.least.int64)
  metrics.set(beacon_end, ctx.layout.endBn.int64)
  metrics.set(beacon_beacon_block_number, ctx.lhc.beacon.header.number.int64)

  metrics.set(beacon_headers_staged_queue_len, ctx.headersStagedQueueLen())
  metrics.set(beacon_headers_unprocessed,
              (ctx.headersUnprocTotal() + ctx.headersUnprocBorrowed()).int64)

  metrics.set(beacon_blocks_staged_queue_len, ctx.blocksStagedQueueLen())
  metrics.set(beacon_blocks_unprocessed,
              (ctx.blocksUnprocTotal() + ctx.blocksUnprocBorrowed()).int64)

  metrics.set(beacon_number_of_buddies, ctx.pool.nBuddies)

# End
