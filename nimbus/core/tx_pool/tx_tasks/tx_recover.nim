# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Recover From Waste Basket or Create
## =============================================================
##

import
  ../tx_desc,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/common/[transactions, addresses, keys],
  stew/keyed_queue

{.push raises: [].}

logScope:
  topics = "tx-pool recover item"

let
  nullSender = block:
    var rc: Address
    rc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc recoverItem*(xp: TxPoolRef; tx: PooledTransaction; status = txItemPending;
                  info = ""; acceptExisting = false): Result[TxItemRef,TxInfo] =
  ## Recover item from waste basket or create new. It is an error if the item
  ## is in the buckets database, already.
  ##
  ## If thy argument `acceptExisting` is set `true` and the tx item is in the
  ## bucket database already for any bucket, the fuction successds ok.
  let itemID = tx.itemID

  # Test whether the item is in the database, already
  if xp.txDB.byItemID.hasKey(itemID):
    if acceptExisting:
      return ok(xp.txDB.byItemID.eq(itemID).value)
    else:
      return err(txInfoErrAlreadyKnown)

  # Check whether the tx can be re-cycled from waste basket
  block:
    let rc = xp.txDB.byRejects.delete(itemID)
    if rc.isOk:
      let item = rc.value.data
      # must not be a waste tx without meta-data
      if item.sender != nullSender:
        let itemInfo = if info != "": info else: item.info
        item.init(status, itemInfo)
        return ok(item)

  # New item generated from scratch, e.g. with `nullSender`
  block:
    let rc = TxItemRef.new(tx, itemID, status, info)
    if rc.isOk:
      return ok(rc.value)

  err(txInfoErrInvalidSender)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
