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
  ../../worker_desc

declareGauge flare_beacon_block_number, "" &
  "Block number for latest finalised header"

declareGauge flare_era1_max_block_number, "" &
  "Max block number for era1 blocks"

declareGauge flare_max_trusted_block_number, "" &
  "Max block number for trusted headers chain starting at genesis"

declareGauge flare_least_verified_block_number, "" &
  "Starting block number for verified higher up headers chain"

declareGauge flare_top_verified_block_number, "" &
  "Top block number for verified higher up headers chain"

declareGauge flare_staged_headers_queue_size, "" &
  "Number of isolated verified header chains, gaps to be filled"

declareGauge flare_number_of_buddies, "" &
  "Number of current worker instances"

declareCounter flare_serial, "" &
  "Serial counter for debugging"

template updateMetricsImpl*(ctx: FlareCtxRef) =
  let now = Moment.now()
  if ctx.pool.nextUpdate < now:
    metrics.set(flare_era1_max_block_number, ctx.pool.e1AvailMax.int64)
    metrics.set(flare_max_trusted_block_number, ctx.layout.base.int64)
    metrics.set(flare_least_verified_block_number, ctx.layout.least.int64)
    metrics.set(flare_top_verified_block_number, ctx.layout.final.int64)
    metrics.set(flare_beacon_block_number, ctx.lhc.beacon.header.number.int64)
    metrics.set(flare_staged_headers_queue_size, ctx.lhc.staged.len)
    metrics.set(flare_number_of_buddies, ctx.pool.nBuddies)
    flare_serial.inc(1)
    ctx.pool.nextUpdate += metricsUpdateInterval

# End
