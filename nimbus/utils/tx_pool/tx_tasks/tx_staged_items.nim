#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Update Staged Queue/Bucket
## ====================================================
##

import
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  ./tx_generic_items

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc stagedItemsReorg*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Stage items to be included into a block. This function re-builds the
  ## `staged` bucket/queue.
  let
    param = TxClassify(
      stageSelect: xp.stageSelect,
      minFeePrice: xp.minFeePrice,
      minTipPrice: xp.minTipPrice)

    # re-org both, the union of `pending` + `staged` buckets
    src: TxReorgBuckets = (
      left: txItemPending,
      right: txItemStaged)

    # all non-`staged` results are fed back into the `queued` bucket
    trg: TxReorgBuckets = (
      left: txItemQueued,
      right: txItemStaged)

  xp.genericItemsReorg(
    inBuckets = src,
    outBuckets = trg,
    outRightFn = classifyTxStaged,
    fnParam = param)


proc stagedItemsAppend*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Collect more items from the `pending` bucket/queue and add them to the
  ## `staged` bucket.
  let param = TxClassify(
    stageSelect: xp.stageSelect,
    minFeePrice: xp.minFeePrice,
    minTipPrice: xp.minTipPrice)

  for itemList in xp.txDB.byStatus.incItemList(txItemPending):
    for item in itemList.walkItems:
      if xp.classifyTxStaged(item,param):
        discard xp.txDB.reassign(item, txItemStaged)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
