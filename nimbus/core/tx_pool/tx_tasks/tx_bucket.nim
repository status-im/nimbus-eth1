# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklets: Update by Bucket
## ===========================================
##

import
  std/[tables],
  ../../../constants,
  ../tx_chain,
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  ../tx_tabs/tx_status,
  ./tx_classify,
  ./tx_dispose,
  chronicles,
  eth/[common, keys],
  stew/[sorted_set]

{.push raises: [].}

const minNonce = AccountNonce.low

logScope:
  topics = "tx-pool buckets"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc bucketItemsReassignPending*(
    xp: TxPoolRef, labelFrom: TxItemStatus, account: EthAddress, nonceFrom = minNonce
) {.gcsafe, raises: [CatchableError].} =
  ## Move all items in bucket `lblFrom` with nonces not less than `nonceFrom`
  ## to the `pending` bucket
  let rc = xp.txDB.byStatus.eq(labelFrom).eq(account)
  if rc.isOk:
    for item in rc.value.data.incNonce(nonceFrom):
      discard xp.txDB.reassign(item, txItemPending)

proc bucketItemsReassignPending*(
    xp: TxPoolRef, item: TxItemRef
) {.gcsafe, raises: [CatchableError].} =
  ## Variant of `bucketItemsReassignPending()`
  xp.bucketItemsReassignPending(item.status, item.sender, item.tx.nonce)

proc bucketUpdateAll*(
    xp: TxPoolRef
): bool {.discardable, gcsafe, raises: [CatchableError].} =
  ## Update all buckets. The function returns `true` if some items were added
  ## to the `staged` bucket.

  # Sort order: `EthAddress` > `AccountNonce` > item.
  var
    stagedItemsAdded = false
    stashed: Table[EthAddress, seq[TxItemRef]]

  # Prepare
  if 0 < xp.pDoubleCheck.len:
    for item in xp.pDoubleCheck:
      if item.reject == txInfoOk:
        # Check whether there was a gap when the head was moved backwards.
        let rc = xp.txDB.bySender.eq(item.sender).sub.gt(item.tx.nonce)
        if rc.isOk:
          let nextItem = rc.value.data
          if item.tx.nonce + 1 < nextItem.tx.nonce:
            discard xp.disposeItemAndHigherNonces(
              item, txInfoErrNonceGap, txInfoErrImpliedNonceGap
            )
      else:
        # For failed txs, make sure that the account state has not
        # changed. Assuming that this list is complete, then there are
        # no other account affected.
        let rc = xp.txDB.bySender.eq(item.sender).sub.ge(minNonce)
        if rc.isOk:
          let firstItem = rc.value.data
          if not xp.classifyValid(firstItem):
            discard xp.disposeItemAndHigherNonces(
              firstItem, txInfoErrNonceGap, txInfoErrImpliedNonceGap
            )

    # Clean up that queue
    xp.pDoubleCheckFlush

  # PENDING
  #
  # Stash the items from the `pending` bucket  The nonces in this list are
  # greater than the ones from other lists. When processing the `staged`
  # list, all that can happen is that loer nonces (than the stashed ones)
  # are added.
  for (sender, nonceList) in xp.txDB.incAccount(txItemPending):
    # New per-sender-account sub-sequence
    stashed[sender] = newSeq[TxItemRef]()
    for item in nonceList.incNonce:
      # Add to sub-sequence
      stashed[sender].add item

  # STAGED
  #
  # Update/edit `staged` bucket.
  for (_, nonceList) in xp.txDB.incAccount(txItemStaged):
    for item in nonceList.incNonce:
      if not xp.classifyActive(item):
        # Larger nonces cannot be held in the `staged` bucket anymore for this
        # sender account. So they are moved back to the `pending` bucket.
        xp.bucketItemsReassignPending(item)

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
  for (_, nonceList) in xp.txDB.incAccount(txItemPacked):
    for item in nonceList.incNonce:
      if not xp.classifyActive(item):
        xp.bucketItemsReassignPending(item)

        # For the `sender` all staged items have smaller nonces, so they have
        # to go to the `pending` bucket, as well.
        xp.bucketItemsReassignPending(txItemStaged, item.sender)
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

  stagedItemsAdded

# ---------------------------

proc bucketFlushPacked*(xp: TxPoolRef) {.gcsafe, raises: [CatchableError].} =
  ## Move all items from the `packed` bucket to the `pending` bucket
  for (_, nonceList) in xp.txDB.decAccount(txItemPacked):
    for item in nonceList.incNonce:
      discard xp.txDB.reassign(item, txItemStaged)

  # Reset bucket status info
  xp.chain.clearAccounts

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
