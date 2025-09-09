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
  pkg/[eth/common, metrics, results],
  pkg/stew/[interval_set, sorted_set],
  ../worker_desc

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

proc blocksStagedQueueInsert*(
    ctx: BeaconCtxRef;
    key: BlockNumber;
      ): Opt[SortedSetItemRef[BlockNumber,BlocksForImport]] =
  let qItem = ctx.blk.staged.insert(key).valueOr:
    return err()
  metrics.set(nec_sync_block_lists_staged, ctx.blk.staged.len)
  ok(qItem)

proc blocksStagedQueueDelete*(
    ctx: BeaconCtxRef;
    key: BlockNumber;
     ) =
  discard ctx.blk.staged.delete(key)
  metrics.set(nec_sync_block_lists_staged, ctx.blk.staged.len)

# ----------------

proc blocksStagedQueueClear*(ctx: BeaconCtxRef) =
  ## Clear queue
  ctx.blk.staged.clear()
  ctx.blk.reserveStaged = 0
  metrics.set(nec_sync_block_lists_staged, 0)

proc blocksStagedQueueInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.blk.staged = StagedBlocksQueue.init()

# End
