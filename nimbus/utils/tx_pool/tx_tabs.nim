# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Basic Primitives
## =================================
##
## Current transaction data organisation:
##
## * All incoming transactions are queued (see `tx_queue` module)
## * Transactions indexed/bucketed by *gas price* (see `tx_list` module)
## * Transactions are grouped by sender address (see `tx_group`)
##

import
  ../keequ,
  ../slst,
  ./tx_info,
  ./tx_item,
  ./tx_tabs/[tx_itemid, tx_leaf, tx_price, tx_sender, tx_status, tx_tipcap],
  eth/[common, keys],
  stew/results

export
  tx_itemid, tx_leaf, tx_price, tx_sender, tx_status, tx_tipcap

type
  TxTabsStatsCount* = tuple
    local, remote: int             ## sum => total
    queued, pending, included: int ## sum => total
    total: int                     ## sum => total

  TxTabsRef* = ref object ##\
    ## Base descriptor
    baseFee: GasInt           ## `byGasTip` re-org when changing
    byItemID*: TxItemIDTab    ## Primary table, queued by arrival event
    byGasTip*: TxPriceTab     ## Indexed by `effectiveGasTip` > `nonce`
    byTipCap*: TxTipCapTab    ## Indexed by `gasTipCap`
    bySender*: TxSenderTab    ## Indexed by `sender` > `local/status` > `nonce`
    byStatus*: TxStatusTab    ## Indexed by `status` > `nonce`

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# core/types/transaction.go(346): .. EffectiveGasTipValue(baseFee ..
proc updateEffectiveGasTip(xp: TxTabsRef): TxPriceItemMap =
  ## This function constucts a `TxPriceItemMap` closure.
  if GasInt.low < xp.baseFee:
    let baseFee = xp.baseFee
    result = proc(item: TxItemRef) =
      # returns the effective miner `gasTipCap` for the given base fee
      # (which might well be negative.)
      item.effectiveGasTip = min(item.tx.gasTipCap, item.tx.gasFeeCap - baseFee)
  else:
    result = proc(item: TxItemRef) =
      item.effectiveGasTip = item.tx.gasTipCap

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxTabsRef; baseFee = GasInt.low): T =
  ## Constructor, returns new tx-pool descriptor.
  new result
  result.baseFee = baseFee
  result.byItemID.txInit
  result.byGasTip.txInit(update = result.updateEffectiveGasTip)
  result.byTipCap.txInit
  result.bySender.txInit
  result.byStatus.txInit

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(xp: TxTabsRef; tx: var Transaction;
             local = false; status = txItemQueued; info = ""):
           Result[void,TxInfo] {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add new transaction argument `tx` to the database. If accepted and added
  ## to the database, a `key` value is returned which can be used to retrieve
  ## this transaction direcly via `tx[key].tx`. The following holds for the
  ## returned `key` value (see `[]` below for details):
  ## ::
  ##   xp[key].id == key  # id: transaction key stored in the wrapping container
  ##   tx.toKey == key    # holds as long as tx is not modified
  ##
  ## Adding the transaction will be rejected if the transaction key `tx.toKey`
  ## exists in the database already.
  ##
  ## CAVEAT:
  ##   The returned transaction key `key` for the transaction `tx` is
  ##   recoverable as `tx.toKey` only while the trasaction remains unmodified.
  ##
  let itemID = tx.itemID
  if xp.byItemID.hasKey(itemID):
    return err(txTabsErrAlreadyKnown)
  let rc = tx.newTxItemRef(itemID, local, status, info)
  if rc.isErr:
    return err(txTabsErrInvalidSender)
  let item = rc.value
  xp.byItemID.txAppend(item)
  xp.byGasTip.txInsert(item)
  xp.byTipCap.txInsert(item)
  xp.bySender.txInsert(item)
  xp.byStatus.txInsert(item)
  ok()


proc reassign*(xp: TxTabsRef; item: TxItemRef; local: bool): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Reassign transaction local/remote flag of a database entry. The function
  ## succeeds returning the transaction item if the transaction was found with
  ## a different local/remote flag than the argument `local` and subsequently
  ## changed.
  # make sure that the argument `item` is not some copy
  let rc = xp.byItemID.eq(item.itemID)
  if rc.isOK:
    var realItem = rc.value
    if realItem.local != local:
      discard xp.bySender.txDelete(realItem) # delete original
      discard xp.byItemID.txDelete(realItem)
      realItem.local = local
      xp.bySender.txInsert(realItem)         # re-insert changed
      xp.byItemID.txAppend(realItem)
      return true

proc reassign*(xp: TxTabsRef; item: TxItemRef; status: TxItemStatus): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `reassign()` for the `TxItemStatus` flag.
  # make sure that the argument `item` is not some copy
  let rc = xp.byItemID.eq(item.itemID)
  if rc.isOK:
    var realItem = rc.value
    if realItem.status != status:
      discard xp.bySender.txDelete(realItem) # delete original
      discard xp.byStatus.txDelete(realItem)
      realItem.status = status
      xp.bySender.txInsert(realItem)         # re-insert changed
      xp.byStatus.txInsert(realItem)
      return true


proc delete*(xp: TxTabsRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  if xp.byItemID.txDelete(item):
    xp.byGasTip.txDelete(item)
    xp.byTipCap.txDelete(item)
    discard xp.bySender.txDelete(item)
    discard xp.byStatus.txDelete(item)
    return true


proc delete*(xp: TxTabsRef; itemID: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Variant of `delete()`
  let rc = xp.byItemID.eq(itemID)
  if rc.isOK:
    let item = rc.value
    if xp.delete(item):
      return ok(item)
  err()

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc baseFee*(xp: TxTabsRef): GasInt {.inline.} =
  ## Get the `baseFee` implying the price list valuation and order. If
  ## this entry is disabled, the value `GasInt.low` is returnded.
  xp.baseFee

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(xp: TxTabsRef; baseFee: GasInt)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Setter, new base fee (implies reorg). The argument `GasInt.low`
  ## disables the `baseFee`.
  xp.baseFee = baseFee
  xp.byGasTip.update = xp.updateEffectiveGasTip

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

proc hasTx*(xp: TxTabsRef; tx: Transaction): bool {.inline.} =
  ## Returns `true` if the argument pair `(key,local)` exists in the
  ## database.
  ##
  ## If this function returns `true`, then it is save to use the `xp[key]`
  ## paradigm for accessing a transaction container.
  xp.byItemID.hasKey(tx.itemID)

proc statsCount*(xp: TxTabsRef): TxTabsStatsCount
    {.gcsafe,raises: [Defect,KeyError].} =
  result.pending = xp.byStatus.eq(txItemPending).nItems
  result.queued = xp.byStatus.eq(txItemQueued).nItems

  result.included = xp.byStatus.eq(txItemIncluded).nItems
  result.local = xp.byItemID.eq(local = true).nItems
  result.remote = xp.byItemID.eq(local = false).nItems

  result.total = result.local + result.remote


# ------------------------------------------------------------------------------
# Public iterators, `sender` > `local` > `nonce` > `item`
# ------------------------------------------------------------------------------

iterator walkItemList*(senderTab: var TxSenderTab): TxLeafItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over item lists grouped by sender addresses.
  var rcAddr = senderTab.first
  while rcAddr.isOK:
    let (addrKey, schedList) = (rcAddr.value.key, rcAddr.value.data)

    for local in [true, false]:
      let rcSched = schedList.eq(local)

      if rcSched.isOk:
        let nonceList = rcSched.value.data

        var rcNonce = nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
          yield itemList
          rcNonce = nonceList.gt(nonceKey)

    rcAddr = senderTab.next(addrKey)


iterator walkSchedList*(senderTab: var TxSenderTab): TxSenderSchedRef =
  ## Walk over item lists grouped by sender addresses and local/remote. This
  ## iterator stops at the `TxSenderSchedRef` level sub-list.
  var rcAddr = senderTab.first
  while rcAddr.isOK:
    let (addrKey, schedList) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = senderTab.next(addrKey)
    yield schedList

iterator walkNonceList*(senderTab: var TxSenderTab;
                        local: varArgs[bool]): TxSenderNonceRef =
  ## Walk over item lists grouped by sender addresses and local/remote. This
  ## iterator stops at the `TxSenderNonceRef` level sub-list.
  var rcAddr = senderTab.first
  while rcAddr.isOK:
    let (addrKey, schedList) = (rcAddr.value.key, rcAddr.value.data)

    for isLocal in local:
      let rcSched = schedList.eq(isLocal)
      if rcSched.isOk:
        let nonceList = rcSched.value.data
        yield nonceList

    rcAddr = senderTab.next(addrKey)

iterator walkItemList*(nonceList: TxSenderNonceRef): TxLeafItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Top level part to replace `xp.bySender.walkItem` with:
  ## ::
  ##  for nonceList in xp.bySender.walkNonceList(true,false):
  ##    for itemList in nonceList.walkItemList:
  ##      for item in itemList.walkItems:
  ##        ...
  ##
  var rcNonce = nonceList.ge(AccountNonce.low)
  while rcNonce.isOk:
    let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
    yield itemList
    rcNonce = nonceList.gt(nonceKey)

iterator walkItemList*(schedList: TxSenderSchedRef): TxLeafItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Top level part to replace `xp.bySender.walkItem` with:
  ## ::
  ##  for schedList in xp.bySender.walkSchedList(true,false):
  ##    for schedList in nonceList.walkItemList:
  ##      for item in itemList.walkItems:
  ##        ...
  ##
  let nonceList = schedList.any.value.data
  var rcNonce = nonceList.ge(AccountNonce.low)
  while rcNonce.isOk:
    let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
    yield itemList
    rcNonce = nonceList.gt(nonceKey)

#[
# deprecated

iterator walkItemList*(schedList: TxSenderSchedRef;
                       sched: TxSenderSchedule): TxLeafItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = schedList.eq(sched)
  if rc.isOK:
    let nonceList = rc.value.data
    var rcNonce = nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
      yield itemList
      rcNonce = nonceList.gt(nonceKey)
]#

iterator walkItemList*(schedList: TxSenderSchedRef;
                       status: TxItemStatus): TxLeafItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = schedList.eq(status)
  if rc.isOK:
    let nonceList = rc.value.data
    var rcNonce = nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
      yield itemList
      rcNonce = nonceList.gt(nonceKey)

# ------------------------------------------------------------------------------
# Public iterators, `effectiveGasTip` > `nonce` > `item`
# -----------------------------------------------------------------------------

iterator incItemList*(priceTab: var TxPriceTab;
                      minPrice = GasInt.low): TxLeafItemRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## gas prices followed by nonces.
  ##
  ## :Note:
  ##   When running in a loop it is ok to add or delete any entries,
  ##   vistied or not visited yet. So, deleting all entries with gas prices
  ##   less or equal than `delMin` would look like:
  ##   ::
  ##    for itemList in xp.byGasTip.incItemList(minPrice = delMin):
  ##      for item in itemList.walkItems:
  ##        discard xq.delete(item)
  var rcGas = priceTab.ge(minPrice)
  while rcGas.isOk:
    let (gasKey, nonceList) = (rcGas.value.key, rcGas.value.data)

    var rcNonce = nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
      yield itemList
      rcNonce = nonceList.gt(nonceKey)

    rcGas = priceTab.gt(gaskey)


iterator incNonceList*(priceTab: var TxPriceTab;
                       minPrice = GasInt.low): TxPriceNonceRef =
  ## Starting at the lowest gas price, this iterator traverses increasing
  ## gas prices. Contrary to `incItem()`, this iterator does not
  ## descent into the none sub-list and rather returns it.
  var rcGas = priceTab.ge(minPrice)
  while rcGas.isOk:
    let (gasKey, nonceList) = (rcGas.value.key, rcGas.value.data)
    yield nonceList
    rcGas = priceTab.gt(gaskey)

iterator incItemList*(nonceList: TxPriceNonceRef;
                      minNonce = AccountNonce.low): TxLeafItemRef =
  ## Second part of a cascaded replacement for `incItem()`:
  ## ::
  ##   for gasData in xp.byGasTip.incNonce:
  ##     for itemData in gasData.incItem:
  ##       ...
  var rcNonce = nonceList.ge(minNonce)
  while rcNonce.isOk:
    let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
    yield itemList
    rcNonce = nonceList.gt(nonceKey)


iterator decItemList*(priceTab: var TxPriceTab;
                      maxPrice = GasInt.high): TxLeafItemRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `incItem()`.
  var rcGas = priceTab.le(maxPrice)
  while rcGas.isOk:
    let (gasKey, nonceList) = (rcGas.value.key, rcGas.value.data)

    var rcNonce = nonceList.le(AccountNonce.high)
    while rcNonce.isOk:
      let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
      yield itemList
      rcNonce = nonceList.lt(nonceKey)

    rcGas = priceTab.lt(gaskey)

iterator decNonceList*(priceTab: var TxPriceTab;
                       maxPrice = GasInt.high): TxPriceNonceRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## gas prices. Contrary to `decItem()`, this iterator does not
  ## descent into the none sub-list and rather returns it.
  var rcGas = priceTab.le(maxPrice)
  while rcGas.isOk:
    let (gasKey, nonceList) = (rcGas.value.key, rcGas.value.data)
    yield nonceList
    rcGas = priceTab.lt(gaskey)

iterator decItemList*(nonceList: TxPriceNonceRef;
                      maxNonce = AccountNonce.high): TxLeafItemRef =
  ## Second part of a cascaded replacement for `decItem()`:
  ## ::
  ##   for gasData in xp.byGasTip.decNonce():
  ##     for itemData in gasData.decItem:
  ##       ...
  var rcNonce = nonceList.le(maxNonce)
  while rcNonce.isOk:
    let (nonceKey, itemList) = (rcNonce.value.key, rcNonce.value.data)
    yield itemList
    rcNonce = nonceList.lt(nonceKey)

# ------------------------------------------------------------------------------
# Public iterators, `gasTipCap` > `item`
# -----------------------------------------------------------------------------

iterator incItemList*(gasTab: var TxTipCapTab;
                      minCap = GasInt.low): TxLeafItemRef =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## See also the **Note* at the comment for `byTipCap.incItem()`.
  var rc = gasTab.ge(minCap)
  while rc.isOk:
    let gasKey = rc.value.key
    yield rc.value.data
    rc = gasTab.gt(gasKey)

iterator decItemList*(gasTab: var TxTipCapTab;
                      maxCap = GasInt.high): TxLeafItemRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `byTipCap.incItem()`.
  var rc = gasTab.le(maxCap)
  while rc.isOk:
    let gasKey = rc.value.key
    yield rc.value.data
    rc = gasTab.lt(gasKey)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: TxTabsRef): Result[void,TxVfyError]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.byGasTip.txVerify
    if rc.isErr:
      return rc
  block:
    let rc = xp.byTipCap.txVerify
    if rc.isErr:
      return rc
  block:
    let rc = xp.bySender.txVerify
    if rc.isErr:
      return rc
  block:
    let rc = xp.byItemID.txVerify
    if rc.isErr:
      return rc
  block:
    let rc = xp.byStatus.txVerify
    if rc.isErr:
      return rc

  for status in TxItemStatus:
    var
      senderCount = 0
      rcAddr = xp.bySender.first
    while rcAddr.isOk:
      let (addrKey, schedData) = (rcAddr.value.key, rcAddr.value.data)
      rcAddr = xp.bySender.next(addrKey)
      senderCount += schedData.eq(status).nItems
    if xp.byStatus.eq(status).nItems != senderCount:
      return err(txVfyStatusSenderTotal)

  if xp.byItemID.nItems != xp.bySender.nItems:
     return err(txVfySenderTotal)

  if xp.byItemID.nItems != xp.byGasTip.nItems:
     return err(txVfyGasTipTotal)

  if xp.byItemID.nItems != xp.byTipCap.nItems:
     return err(txVfyTipCapTotal)

  if xp.byItemID.nItems != xp.byStatus.nItems:
     return err(txVfyStatusTotal)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
