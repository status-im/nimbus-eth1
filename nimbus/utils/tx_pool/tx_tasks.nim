# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklets
## =========================
##
## These tasks do not know about the `TxPool` descriptor (parameters must
## be passed as function argument.)

import
  std/[times],
  ../keequ,
  ../slst,
  ./tx_gauge,
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  chronicles,
  eth/[common, keys],
  stew/results

logScope:
  topics = "tx-pool helper"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc utcNow: Time =
  now().utc.toTime

#proc pp(t: Time): string =
#  t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff", utc())

# ------------------------------------------------------------------------------
# Global functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(384): for addr := range pool.queue {
proc deleteExpiredItems*(tDB: TxTabsRef; maxLifeTime: Duration)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Any non-local transaction old enough will be removed
  let deadLine = utcNow() - maxLifeTime
  var rc = tDB.byItemID.eq(local = false).first
  while rc.isOK:
    let item = rc.value.data
    if deadLine < item.timeStamp:
      break
    rc = tDB.byItemID.eq(local = false).next(item.itemID)
    discard tDB.reject(item,txInfoErrTxExpired)
    queuedEvictionMeter(1)


# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc deleteUnderpricedItems*(tDB: TxTabsRef; price: GasInt)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Drop all transactions below the argument threshold `price`, i.e.
  ## move these items to the waste basket.
  # Delete while walking the `gasFeeCap` table (it is ok to delete the
  # current item). See also `remotesBelowTip()`.
  for itemList in tDB.byTipCap.decItemList(maxCap = price - 1):
    for item in itemList.walkItems:
      if not item.local:
        discard tDB.reject(item,txInfoErrUnderpriced)


# core/tx_pool.go(889): func (pool *TxPool) addTxs(txs []*types.Transaction, ..
proc addTxs*(tDB: TxTabsRef; txs: openArray[Transaction];
             local: bool; status: TxItemStatus; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Queue a batch of transactions. There transactions are quickly tested
  ## and moved to the waiting queue, or into the waste basket.
  for i in 0 ..< txs.len:
    var tx = txs[i]
    let rc = tDB.insert(tx, local, status, info)

    if rc.isOk:
      validTxMeter(1)
      continue

    # store tx in waste basket
    tDB.reject(tx, rc.error, local, status, info)

    # update gauge
    case rc.error:
    of txInfoErrAlreadyKnown:
      knownTxMeter(1)
    of txInfoErrInvalidSender:
      invalidTxMeter(1)
    else:
      unspecifiedErrorMeter(1)


# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc collectAccounts*(tDB: TxTabsRef; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered local by the pool.
  var rc = tDB.bySender.first
  while rc.isOK:
    let (addrKey, schedList) = (rc.value.key, rc.value.data)
    rc = tDB.bySender.next(addrKey)
    if 0 < schedList.eq(local).nItems:
      result.add addrKey


# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc reassignRemoteToLocals*(tDB: TxTabsRef; signer: EthAddress): int
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  let rc = tDB.bySender.eq(signer).eq(local = false)
  if rc.isOK:
    let nRemotes = tDB.byItemID.eq(local = false).nItems
    for itemList in rc.value.data.walkItemList:
      for item in itemList.walkItems:
        discard tDB.reassign(item, local = true)
    return nRemotes - tDB.byItemID.eq(local = false).nItems


# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc getRemotesBelowTip*(tDB: TxTabsRef; threshold: GasInt): seq[Hash256]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold.
  for itemList in tDB.byTipCap.decItemList(maxCap = threshold - 1):
    for item in itemList.walkItems:
      if not item.local:
        result.add item.itemID


proc updateGasPrice*(tDB: TxTabsRef; curPrice: var GasInt; newPrice: GasInt)
    {.inline, raises: [Defect,KeyError].} =
  let oldPrice = curPrice
  curPrice = newPrice

  # if min miner fee increased, remove txs below the new threshold
  if oldPrice < newPrice:
    tDB.deleteUnderpricedItems(newPrice)

  info "Price threshold updated",
     oldPrice,
     newPrice

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
