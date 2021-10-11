# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Update Pending Queue
## ==============================================
##

import
  ../tx_desc,
  ../tx_item,
  ./tx_classify,
  ./tx_generic_items

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc pendingItemsUpdate*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Rebuild `pending` and `queued` buckets.
  let
    param = TxClassify(
      gasLimit: xp.dbHead.trgGasLimit,
      baseFee: xp.dbHead.baseFee)

    buckets: TxReorgBuckets = (
      left: txItemQueued,
      right: txItemPending)

  xp.genericItemsReorg(
    inBuckets = buckets,
    outBuckets = buckets,
    outRightFn = classifyTxPending,
    fnParam = param)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
