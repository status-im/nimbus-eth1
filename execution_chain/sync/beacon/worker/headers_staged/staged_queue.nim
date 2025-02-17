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
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ../../worker_desc

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

# ----------------

func headersStagedQueueClear*(ctx: BeaconCtxRef) =
  ## Clear queue
  ctx.hdr.staged.clear

func headersStagedQueueInit*(ctx: BeaconCtxRef) =
  ## Constructor
  ctx.hdr.staged = LinkedHChainQueue.init()

# End
