#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Update Packed Bucket
## ==============================================
##

import
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  ./tx_generic_items

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc packedItemsReorg*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Stage items to be included into a block. This function re-builds the
  ## `packed` bucket/queue.
  let
    param = TxClassify(
      stageSelect: xp.algoSelect,
      minPlGasPrice: xp.minPlGasPrice,
      minFeePrice: xp.minFeePrice,
      minTipPrice: xp.minTipPrice)

    # re-org both, the union of `staged` + `packed` buckets
    src: TxReorgBuckets = (
      left: txItemStaged,
      right: txItemPacked)

    # all non-`packed` results are fed back into the `pending` bucket
    trg: TxReorgBuckets = (
      left: txItemPending,
      right: txItemPacked)

  xp.genericItemsReorg(
    inBuckets = src,
    outBuckets = trg,
    outRightFn = classifyTxPacked,
    fnParam = param)


proc packedItemsAppend*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Collect more items from the `staged` bucket and add them to the
  ## `packed` bucket.
  let param = TxClassify(
    stageSelect: xp.algoSelect,
    minFeePrice: xp.minFeePrice,
    minTipPrice: xp.minTipPrice)

  for item in xp.txDB.byStatus.incItemList(txItemStaged):
    if xp.classifyTxPacked(item,param):
      discard xp.txDB.reassign(item, txItemPacked)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
