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
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  ../tx_tabs/tx_status,
  ./tx_classify,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool buckets"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc reassignItemsPending(xp: TxPoolRef; labelFrom: TxItemStatus;
                          account: EthAddress; nonceFrom = AccountNonce.low)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Move all items in bucket `lblFrom` with nonces not less than `nonceFrom`
  ## to the `pending` bucket
  let rc = xp.txDB.byStatus.eq(labelFrom).eq(account)
  if rc.isOK:
    for item in rc.value.data.incItemList(nonceFrom):
      discard xp.txDB.reassign(item, txItemPending)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc bucketsUpdateAll*(xp: TxPoolRef): bool
    {.discardable,gcsafe,raises: [Defect,CatchableError].} =
  ## Update all buckets. The function returns `true` if some items were added
  ## to the `staged` bucket.

  # Sort order: `EthAddress` > `AccountNonce` > item.
  var
    stagedItemsAdded = false
    stashed: Table[EthAddress,seq[TxItemRef]]

  # PENDING
  #
  # Stash the items from the `pending` bucket  The nonces in this list are
  # greater than the ones from other lists. When processing the `staged`
  # list, all that can happen is that loer nonces (than the stashed ones)
  # are added.
  for (sender,nonceList) in xp.txDB.byStatus.walkAccountPair(txItemPending):
    # New per-sender-account sub-sequence
    stashed[sender] = newSeq[TxItemRef]()
    for item in nonceList.incItemList:
      # Add to sub-sequence
      stashed[sender].add item

  # STAGED
  #
  # Update/edit `staged` bucket.
  for (_,nonceList) in xp.txDB.byStatus.walkAccountPair(txItemStaged):
    for item in nonceList.incItemList:

      if not xp.classifyActive(item):
        # Larger nonces cannot be held in the `staged` bucket anymore for this
        # sender account. So they are moved back to the `pending` bucket.
        xp.reassignItemsPending(txItemStaged, item.sender, item.tx.nonce)

        # The nonces in the `staged` bucket are always smaller than the one in
        # the `pending` bucket. So, if the lower nonce items must go to the
        # `pending` bucket, then the stashed `pending` bucket items can only
        # stay there.
        stashed.del(item.sender)
        break # inner `incItemList()` loop

  # PACKED
  #
  # Update `packed` bucket. The items are a subset of all possibly staged
  # (aka active) items. So they follow a similar logic as for the `staged`
  # items above.
  for (_,nonceList) in xp.txDB.byStatus.walkAccountPair(txItemPacked):
    for item in nonceList.incItemList:

      if not xp.classifyActive(item):
        xp.reassignItemsPending(txItemPacked, item.sender, item.tx.nonce)

        # All staged items have smaller nonces for this sender, so they have
        # to go to the `pending` bucket, as well.
        xp.reassignItemsPending(txItemStaged, item.sender)
        stagedItemsAdded = true

        stashed.del(item.sender)
        break # inner `incItemList()` loop

  # PENDING re-visted
  #
  # Post-process `pending` and `staged` buckets. Re-insert the
  # list of stashed `pending` items.
  for itemList in stashed.values:
    for item in itemList:
      if not xp.classifyActive(item):
        # Ignore higher nonces
        break # inner loop for `itemList` sequence
      # Move to staged bucket
      discard xp.txDB.reassign(item, txItemStaged)

  return stagedItemsAdded


proc bucketsUpdatePacked*(xp: TxPoolRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Attempt to pack a new block into the `packed` bucket not exceeding the
  ## block size hard or soft limits (see `xp.pAlgoFlags`.)
  var
    gasTotal = xp.txDB.byStatus.eq(txItemPacked).gasLimits
    stop = false

  block perSenderPack:
    for (_,nonceList) in xp.txDB.byStatus.walkAccountPair(txItemStaged):
      for item in nonceList.incItemList:
        case xp.classifyForPacking(item, gasTotal):
        of rcDoAcceptTx:
          if not xp.txDB.reassign(item, txItemPacked):
            break  # weird case, should not happen
          gasTotal += item.tx.gasLimit
        of rcStopPacking:
          break perSenderPack
        of rcSkipTx:
          break # stop for this sender (inner `incItemList()` loop)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
