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
  pkg/[eth/common, metrics],
  pkg/stew/[interval_set, sorted_set],
  ../worker_desc

declareGauge nec_sync_header_lists_staged, "" &
  "Number of header list records staged for serialised processing"

# ----------------

func headersStagedQueueTopKey*(ctx: BeaconCtxRef): BlockNumber =
  ## Retrieve to staged block number
  let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
    return BlockNumber(0)
  qItem.key

func headersStagedQueueLen*(ctx: BeaconCtxRef): int =
  ## Number of staged records
  ctx.hdr.staged.len

func headersStagedQueueIsEmpty*(ctx: BeaconCtxRef): bool =
  ## `true` iff no data are on the queue.
  ctx.hdr.staged.len == 0

proc headersStagedQueueMetricsUpdate*(ctx: BeaconCtxRef) =
  metrics.set(nec_sync_header_lists_staged, ctx.hdr.staged.len)

# ----------------

proc headersStagedQueueClear*(ctx: BeaconCtxRef) =
  ## Clear queue
  ctx.hdr.staged.clear()
  ctx.hdr.reserveStaged = 0
  metrics.set(nec_sync_header_lists_staged, 0)

proc headersStagedQueueInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.hdr.staged = StagedHeaderQueue.init()
  metrics.set(nec_sync_header_lists_staged, 0)

# End
