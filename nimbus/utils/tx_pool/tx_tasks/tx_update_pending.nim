
# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Add Transaction
## =========================================
##

import
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool update pending queue"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updatePending*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Similar to `addTxs()` only for queued or pending items on the system.
  var
    stashed: seq[TxItemRef]
    stashStatus = txItemQueued
    updateStatus = txItemPending

  # prepare: stash smaller sub-list, update larger one
  let
    nPending = xp.txDB.byStatus.eq(txItemPending).nItems
    nQueued = xp.txDB.byStatus.eq(txItemQueued).nItems
  if nPending < nQueued:
    stashStatus = txItemPending
    updateStatus = txItemQueued

  # action, first step: stash smaller sub-list
  for itemList in xp.txDB.byStatus.incItemList(stashStatus):
    for item in itemList.walkItems:
      stashed.add item

  # action, second step: update larger sub-list
  for itemList in xp.txDB.byStatus.incItemList(updateStatus):
    for item in itemList.walkItems:
      let newStatus =
        if xp.classifyTxPending(item): txItemPending
        else: txItemQueued
      if newStatus != updateStatus:
        discard xp.txDB.reassign(item, newStatus)

  # action, finalise: update smaller, stashed sup-list
  for item in stashed:
    let newStatus =
      if xp.classifyTxPending(item): txItemPending
      else: txItemQueued
    if newStatus != stashStatus:
      discard xp.txDB.reassign(item, newStatus)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
