# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Helper: Reorg two queues/buckets
## =================================================
##

import
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  eth/[common, keys]

type
  TxReorgChooseRight* = ##\
    ## Function argument for `reorgTwoBuckets()` for classifying an item. It
    ## returns `true` if the item belongs to the second status passed
    ## as `reorgTwoBuckets()` function argument.
    proc(xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool
      {.gcsafe,raises: [Defect,CatchableError].}

  TxReorgBuckets* = tuple
    left: TxItemStatus    ## Label of left bucket
    right: TxItemStatus   ## Label of right bucket

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc genericItemsReorg*(
    xp: TxPoolRef;                       ## descriptor
    inBuckets: TxReorgBuckets;           ## Re-distribute both buckets
    outBuckets: TxReorgBuckets;          ## Redistribution target buckets
    outRightFn: TxReorgChooseRight;      ## decision function
    fnParam: TxClassify;                 ## decision function parameters
    ) {.gcsafe,raises: [Defect,CatchableError].} =
  ## Rebuild the two `inBucket` argument labelled buckets by re-classifying its
  ## items. These items are stored into the pair of `outBucket` labelled
  ## buckets according to the value of the argument `outRightFn` filter
  ## function.
  ##
  ## The bucket labels `inBuckets` and `outBuckets` may overlap.
  ##
  ## If the `outRightFn` returns `true`, the corresponding item is re-assigned
  ## to the `right` of `outBuckets` pair, otherwise to the `left`.
  var
    stashed: seq[TxItemRef]
    inStatus = inBuckets # default: left bucket is the smaller one

  # prepare: stash smaller "left" sub-list, update larger one
  let
    nLeft = xp.txDB.byStatus.eq(inBuckets.left).nItems
    nRight = xp.txDB.byStatus.eq(inBuckets.right).nItems
  if nRight < nLeft:
    inStatus.left = inBuckets.right
    inStatus.right = inBuckets.left

  # action, first step: stash smaller "left" sub-list
  for item in xp.txDB.byStatus.incItemList(inStatus.left):
    stashed.add item

  # action, second step: update larger "right" sub-list
  for item in xp.txDB.byStatus.incItemList(inStatus.right):
    let newStatus = if xp.outRightFn(item,fnParam): outBuckets.right
                    else:                           outBuckets.left
    if newStatus != inStatus.right:
      discard xp.txDB.reassign(item, newStatus)

  # action, finalise: update smaller, stashed sup-list
  for item in stashed:
    let newStatus = if xp.outRightFn(item,fnParam): outBuckets.right
                    else:                           outBuckets.left
    if newStatus != inStatus.left:
      discard xp.txDB.reassign(item, newStatus)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
