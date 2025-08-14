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
  ../../worker_desc

declareGauge nec_sync_block_lists_staged, "" &
  "Number of block list records staged for importing"

# ---------------

func blocksStagedQueueBottomKey*(ctx: BeaconCtxRef): BlockNumber =
  ## Retrieve to staged block number
  let qItem = ctx.blk.staged.ge(0).valueOr:
    return high(BlockNumber)
  qItem.key

func blocksStagedQueueLen*(ctx: BeaconCtxRef): int =
  ## Number of staged records
  ctx.blk.staged.len

func blocksStagedQueueIsEmpty*(ctx: BeaconCtxRef): bool =
  ## `true` iff no data are on the queue.
  ctx.blk.staged.len == 0

proc blocksStagedQueueMetricsUpdate*(ctx: BeaconCtxRef) =
  metrics.set(nec_sync_block_lists_staged, ctx.blk.staged.len)

# ----------------

proc blocksStagedQueueClear*(ctx: BeaconCtxRef) =
  ## Clear queue
  ctx.blk.staged.clear()
  ctx.blk.reserveStaged = 0

proc blocksStagedQueueInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.blk.staged = StagedBlocksQueue.init()

# End
