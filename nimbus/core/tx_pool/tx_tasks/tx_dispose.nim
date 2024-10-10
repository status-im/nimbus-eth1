# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Dispose expired items
## ===============================================
##

import
  std/[times],
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/common/[transactions, keys],
  stew/keyed_queue

{.push raises: [].}

logScope:
  topics = "tx-pool dispose expired"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc utcNow: Time =
  getTime().utc.toTime

#proc pp(t: Time): string =
#  t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff", utc())

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc deleteOtherNonces(xp: TxPoolRef; item: TxItemRef; newerThan: Time): bool
    {.gcsafe,raises: [KeyError].} =
  let rc = xp.txDB.bySender.eq(item.sender).sub
  if rc.isOk:
    for other in rc.value.data.incNonce(item.tx.nonce):
      # only delete non-expired items
      if newerThan < other.timeStamp:
        discard xp.txDB.dispose(other, txInfoErrTxExpiredImplied)
        result = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(384): for addr := range pool.queue {
proc disposeExpiredItems*(xp: TxPoolRef) {.gcsafe,raises: [KeyError].} =
  ## Any non-local transaction old enough will be removed. This will not
  ## apply to items in the packed queue.
  let
    deadLine = utcNow() - xp.lifeTime
    dspUnpacked = autoZombifyUnpacked in xp.pFlags

  var rc = xp.txDB.byItemID.first
  while rc.isOk:
    let (key, item) = (rc.value.key, rc.value.data)
    if deadLine < item.timeStamp:
      break
    rc = xp.txDB.byItemID.next(key)

    if item.status != txItemPacked:
      if not dspUnpacked:
        continue

    # Note: it is ok to delete the current item
    discard xp.txDB.dispose(item, txInfoErrTxExpired)

    # Also delete all non-expired items with higher nonces.
    if xp.deleteOtherNonces(item, deadLine):
      if rc.isOk:
        # If one of the "other" just deleted items was the "next(key)", the
        # loop would have stooped anyway at the "if deadLine < item.timeStamp:"
        # clause at the while() loop header.
        if not xp.txDB.byItemID.hasKey(rc.value.key):
          break


proc disposeItemAndHigherNonces*(xp: TxPoolRef; item: TxItemRef;
                                 reason, otherReason: TxInfo): int
    {.gcsafe,raises: [CatchableError].} =
  ## Move item and higher nonces per sender to wastebasket.
  if xp.txDB.dispose(item, reason):
    result = 1
    # For the current sender, delete all items with higher nonces
    let rc = xp.txDB.bySender.eq(item.sender).sub
    if rc.isOk:
      let nonceList = rc.value.data

      for otherItem in nonceList.incNonce(item.tx.nonce):
        if xp.txDB.dispose(otherItem, otherReason):
          result.inc


proc disposeById*(xp: TxPoolRef; itemIDs: openArray[Hash32]; reason: TxInfo)
    {.gcsafe,raises: [KeyError].}=
  ## Dispose items by item ID wihtout checking whether this makes other items
  ## unusable (e.g. with higher nonces for the same sender.)
  for itemID in itemIDs:
    let rcItem = xp.txDB.byItemID.eq(itemID)
    if rcItem.isOK:
      discard xp.txDB.dispose(rcItem.value, reason)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
