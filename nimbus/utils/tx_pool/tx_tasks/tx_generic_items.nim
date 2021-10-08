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
  TxReorgClassify2nd* = ##\
    ## Function argument for `reorgTwoBuckets()` for classifying an item. It
    ## returns `true` if the item belongs to the second status passed
    ## as `reorgTwoBuckets()` function argument.
    proc(xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool
      {.gcsafe,raises: [Defect,CatchableError].}

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc genericItemsReorg*(
    xp: TxPoolRef;                          ## descriptor
    firstStatus: TxItemStatus;              ## name of first bucket
    secondStatus: TxItemStatus;             ## name of second bucket
    isSecondFn: TxReorgClassify2nd;         ## decision function
    fnParam: TxClassify;                      ## decision function parameters
    ) {.gcsafe,raises: [Defect,CatchableError].} =
  ## Rebuild two queues/buckets by re-classifying its item arguments.
  var
    stashed: seq[TxItemRef]
    stashStatus = firstStatus # default: 1st bucket is the smaller one
    updateStatus = secondStatus

  # prepare: stash smaller sub-list, update larger one
  let
    nFirst = xp.txDB.byStatus.eq(firstStatus).nItems
    nSecond = xp.txDB.byStatus.eq(secondStatus).nItems
  if nSecond < nFirst:
    stashStatus = secondStatus
    updateStatus = firstStatus

  # action, first step: stash smaller sub-list
  for itemList in xp.txDB.byStatus.incItemList(stashStatus):
    for item in itemList.walkItems:
      stashed.add item

  # action, second step: update larger sub-list
  for itemList in xp.txDB.byStatus.incItemList(updateStatus):
    for item in itemList.walkItems:
      let newStatus =
        if xp.isSecondFn(item,fnParam): secondStatus
        else: firstStatus
      if newStatus != updateStatus:
        discard xp.txDB.reassign(item, newStatus)

  # action, finalise: update smaller, stashed sup-list
  for item in stashed:
    let newStatus =
      if xp.isSecondFn(item,fnParam): secondStatus
      else: firstStatus
    if newStatus != stashStatus:
      discard xp.txDB.reassign(item, newStatus)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
