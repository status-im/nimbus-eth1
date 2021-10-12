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

import
  std/[times],
  ../keequ,
  ../slst,
  ./tx_desc,
  ./tx_gauge,
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  ./tx_tabs/[tx_itemid, tx_leaf, tx_sender],
  chronicles,
  eth/[common, keys],
  stew/results

logScope:
  topics = "tx-pool tasks"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc utcNow: Time =
  now().utc.toTime

#proc pp(t: Time): string =
#  t.format("yyyy-MM-dd'T'HH:mm:ss'.'fff", utc())

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(384): for addr := range pool.queue {
proc deleteExpiredItems*(xp: TxPoolRef; maxLifeTime: Duration)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Any non-local transaction old enough will be removed
  let deadLine = utcNow() - maxLifeTime
  var rc = xp.txDB.byItemID.eq(local = false).first
  while rc.isOK:
    let item = rc.value.data
    if deadLine < item.timeStamp:
      break
    rc = xp.txDB.byItemID.eq(local = false).next(item.itemID)
    discard xp.txDB.dispose(item,txInfoErrTxExpired)
    queuedEvictionMeter(1)

# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc collectAccounts*(xp: TxPoolRef; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered local by the pool.
  var rc = xp.txDB.bySender.first
  while rc.isOK:
    let (addrKey, schedList) = (rc.value.key, rc.value.data)
    rc = xp.txDB.bySender.next(addrKey)
    if 0 < schedList.eq(local).nItems:
      result.add addrKey


# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc reassignRemoteToLocals*(xp: TxPoolRef; signer: EthAddress): int
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  let rc = xp.txDB.bySender.eq(signer).eq(local = false)
  if rc.isOK:
    let nRemotes = xp.txDB.byItemID.eq(local = false).nItems
    for item in rc.value.data.walkItemList:
      discard xp.txDB.reassign(item, local = true)
    return nRemotes - xp.txDB.byItemID.eq(local = false).nItems


# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc getRemotesBelowTip*(xp: TxPoolRef; threshold: GasPrice): seq[Hash256]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold.
  if 0.GasPrice < threshold:
    for itemList in xp.txDB.byTipCap.decItemList(maxCap = threshold - 1):
      for item in itemList.walkItems:
        if not item.local:
          result.add item.itemID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
