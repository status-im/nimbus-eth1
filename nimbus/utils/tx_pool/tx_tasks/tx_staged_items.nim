# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Update Staged Queue
## =============================================
##

import
  std/[tables],
  ../../sorted_set,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ../tx_tabs/tx_status,
  ./tx_classify,
  eth/[common, keys]

const
  minEthAddress = block:
    var rc: EthAddress
    rc

import std/[sequtils, strutils, strformat]
proc toHex*(acc: EthAddress): string =
  (acc.toSeq.mapIt(&"{it:02x}").join)[14..19]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

iterator bucketListWalk(
        xp: TxPoolRef; label: TxItemStatus): (EthAddress,TxStatusNonceRef) =
  ## For given bucket, visit all sender accounts.
  let rcBucket = xp.txDB.byStatus.eq(label)
  if rcBucket.isOK:
    var rcAcc = rcBucket.ge(minEthAddress)
    while rcAcc.isOK:
      let (sender, nonceList) = (rcAcc.value.key, rcAcc.value.data)
      yield (sender, nonceList)
      rcAcc = rcBucket.gt(sender) # potenially modified database

iterator nonceListWalk(nonceList: TxStatusNonceRef): TxItemRef =
  ## For given nonce list, visit all items with increasing nonce order.
  var rcNonce = nonceList.ge(AccountNonce.low)
  while rcNonce.isOK:
    let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
    yield item
    rcNonce = nonceList.gt(nonceKey) # potenially modified database

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc stagedItemsUpdate*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Rebuild `staged` and `pending` buckets.
  let param = TxClassify(
    gasLimit: xp.dbHead.trgGasLimit,
    baseFee: xp.dbHead.baseFee)

  # Sort order: `EthAddress` > `AccountNonce` > item.
  var stashed: Table[EthAddress,seq[TxItemRef]]

  # Stash the items from the `pending` bucket  The nonces in this list are
  # greater than the ones from other lists. When processing the `staged`
  # list, all that can happen is that loer nonces (than the stashed ones)
  # are added.
  for (sender,nonceList) in xp.bucketListWalk(txItemPending):
    # New per-sender-account sub-sequence
    stashed[sender] = newSeq[TxItemRef]()
    for item in nonceList.nonceListWalk:
      # Add to sub-sequence
      stashed[sender].add item

  # Update/edit `staged` bucket.
  for (sender,nonceList) in xp.bucketListWalk(txItemStaged):
    var moveTail = false
    for item in nonceList.nonceListWalk:
      if moveTail or not xp.classifyTxStaged(item,param):
        # Larger nonces cannot be held in this bucket anymore for this
        # account. So they are moved back to the `pending` bucket.
        discard xp.txDB.reassign(item, txItemPending)
        # The nonces in the `staged` bucket are always smaller than the one in
        # the `pending` bucket. So, if the lower nonce items must go to the
        # `pending` bucket, then the stashed items will stay there as well.
        if not moveTail:
          moveTail = true
          stashed.del(item.sender)

  # Finalise: process stashed `pending` items
  for itemList in stashed.values:
    for item in itemList:
      if not xp.classifyTxStaged(item,param):
        # Ignore higher nonces
        break
      # Move to staged bucket
      discard xp.txDB.reassign(item, txItemStaged)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
