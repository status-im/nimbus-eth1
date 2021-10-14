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
  std/[sequtils, tables],
  ../keequ,
  ../keequ/kq_debug,
  ../slst,
  ./tx_info,
  ./tx_item,
  ./tx_tabs/[tx_leaf, tx_price, tx_sender, tx_status, tx_tipcap],
  eth/[common, keys],
  stew/results

export
  any, eq, first, ge, gt, hasKey, last, le, len, lt,
  nItems, next, prev, walkItems

type
  TxTabsStatsCount* = tuple
    queued, pending, staged: int ## sum => total
    total: int                   ## excluding rejects
    disposed: int                ## waste basket

  TxTabsRef* = ref object ##\
    ## Base descriptor
    maxRejects: int ##\
      ## madximal number of items in waste basket

    baseFee: GasPrice##\
      ## `byGasTip` re-org when changing

    # ----- primary tables ------

    byLocal*: Table[EthAddress,bool] ##\
      ## List of local accounts

    byRejects*: TxLeafItemRef ##\
      ## Rejects queue, waste basket

    byItemID*: KeeQu[Hash256,TxItemRef] ##\
      ## Primary table, queued by arrival event

    # ----- index tables ------

    byGasTip*: TxPriceTab ##\
      ## Index for byItemID, `effectiveGasTip` > `nonce`

    byTipCap*: TxTipCapTab ##\
      ## Index for byItemID, `gasTipCap`

    bySender*: TxSenderTab ##\
      ## Index for byItemID, `sender` > `status` > `nonce`

    byStatus*: TxStatusTab ##\
      ## Index for byItemID, `status` > `nonce`


const
  txTabMaxRejects = ##\
    ## Default size of rejects queue (aka waste basket.) Older waste items will
    ## be automatically removed so that there are no more than this many items
    ## in the rejects queue.
    500

  minEthAddress = block:
    var rc: EthAddress
    rc

  maxEthAddress = block:
    var rc: EthAddress
    for n in 0 ..< rc.len:
      rc[n] = 255
    rc

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# core/types/transaction.go(346): .. EffectiveGasTipValue(baseFee ..
proc updateEffectiveGasTip(xp: TxTabsRef): TxPriceItemMap =
  ## This function constucts a `TxPriceItemMap` closure.
  let baseFee = xp.baseFee
  result = proc(item: TxItemRef) =
    # returns the effective miner gas tip (which might well be negative) for
    # the globally given base fee.
    item.effGasTip = item.tx.estimatedGasTip(baseFee)

proc deleteImpl(xp: TxTabsRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  if xp.byItemID.delete(item.itemID).isOK:
    xp.byGasTip.txDelete(item)
    xp.byTipCap.txDelete(item)
    discard xp.bySender.txDelete(item)
    discard xp.byStatus.txDelete(item)
    return true

proc insertImpl(xp: TxTabsRef; item: TxItemRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
  if not xp.bySender.txInsert(item):
    return err(txInfoErrSenderNonceIndex)
  discard xp.byItemID.append(item.itemID,item)
  xp.byGasTip.txInsert(item)
  xp.byTipCap.txInsert(item)
  xp.byStatus.txInsert(item)
  return ok()

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxTabsRef; baseFee = 0.GasPrice): T =
  ## Constructor, returns new tx-pool descriptor.
  new result
  result.maxRejects = txTabMaxRejects
  result.baseFee = baseFee

  # result.byLocal -- Table, no need to init
  # result.byItemID -- KeeQu, no need to init
  result.byRejects = TxLeafItemRef.txNew

  # index tables
  result.byGasTip.txInit(update = result.updateEffectiveGasTip)
  result.byTipCap.txInit
  result.bySender.txInit
  result.byStatus.txInit

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(
    xp: TxTabsRef;
    tx: var Transaction;
    status = txItemQueued;
    info = ""): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
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
    return err(txInfoErrAlreadyKnown)
  var item: TxItemRef
  block:
    let rc = tx.newTxItemRef(itemID, status, info)
    if rc.isErr:
      return err(txInfoErrInvalidSender)
    item = rc.value
  block:
    let rc = xp.insertImpl(item)
    if rc.isErr:
      return rc
  ok()

proc insert*(xp: TxTabsRef; item: TxItemRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `insert()` with fully qualified `item` argument.
  if xp.byItemID.hasKey(item.itemID):
    return err(txInfoErrAlreadyKnown)
  return xp.insertImpl(item.dup)


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
      discard xp.bySender.txInsert(realItem) # re-insert changed
      xp.byStatus.txInsert(realItem)
      return true


proc flushRejects*(xp: TxTabsRef; maxItems = int.high): (int,int)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Flush/delete at most `maxItems` oldest items from the waste basket and
  ## return the numbers of deleted and remaining items (a waste basket item
  ## is considered older if it was moved there earlier.)
  if xp.byRejects.nItems <= maxItems:
    return (xp.byRejects.txClear,0)
  while result[0] < maxItems:
    if xp.byRejects.txFetch.isErr:
      break
    result[0].inc
  result[1] = xp.byRejects.nItems


proc dispose*(xp: TxTabsRef; item: TxItemRef; reason: TxInfo): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Move argument `item` to rejects queue (aka waste basket.)
  if xp.deleteImpl(item):
    if xp.maxRejects <= xp.byRejects.nItems:
      discard xp.flushRejects(1 + xp.byRejects.nItems - xp.maxRejects)
    item.reject = reason
    return xp.byRejects.txAppend(item)

proc reject*(xp: TxTabsRef; tx: var Transaction;
             reason: TxInfo; status = txItemQueued; info = "")
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to dispose but for a tx without the item wrapper, the function
  ## imports the tx into the waste basket (e.g. after it could not
  ## be inserted.)
  if xp.maxRejects <= xp.byRejects.nItems:
    discard xp.flushRejects(1 + xp.byRejects.nItems - xp.maxRejects)
  let item = tx.newTxItemRef(reason, status, info)
  discard xp.byRejects.txAppend(item)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc baseFee*(xp: TxTabsRef): GasPrice {.inline.} =
  ## Get the `baseFee` implying the price list valuation and order. If
  ## this entry is disabled, the value `GasInt.low` is returnded.
  xp.baseFee

proc maxRejects*(xp: TxTabsRef): int {.inline.} =
  ## Getter
  xp.maxRejects

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(xp: TxTabsRef; baseFee: GasPrice)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Setter, new base fee (implies reorg). The argument `GasInt.low`
  ## disables the `baseFee`.
  if xp.baseFee != baseFee:
    xp.baseFee = baseFee
    xp.byGasTip.update = xp.updateEffectiveGasTip

proc `maxRejects=`*(xp: TxTabsRef; val: int) {.inline.} =
  ## Setter, applicable with next `reject()` invocation.
  xp.maxRejects = val

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
  result.queued = xp.byStatus.eq(txItemQueued).nItems
  result.pending = xp.byStatus.eq(txItemPending).nItems
  result.staged = xp.byStatus.eq(txItemStaged).nItems

  result.total =  xp.byItemID.len

  result.disposed = xp.byRejects.nItems

# ------------------------------------------------------------------------------
# Public functions: local/remote sender accounts
# ------------------------------------------------------------------------------

proc isLocal*(xp: TxTabsRef; sender: EthAddress): bool {.inline.} =
  ## Returns `true` if account address is local
  xp.byLocal.hasKey(sender)

proc locals*(xp: TxTabsRef): seq[EthAddress] {.inline.} =
  ## Returns  an unsorted list of addresses tagged *local*
  toSeq(xp.byLocal.keys)

proc remotes*(xp: TxTabsRef): seq[EthAddress] {.inline.} =
  ## Returns  an unsorted list of untagged addresses
  var rcAddr = xp.bySender.first
  while rcAddr.isOK:
    let sender = rcAddr.value.key
    rcAddr = xp.bySender.next(sender)
    if not xp.byLocal.hasKey(sender):
      result.add sender

proc setLocal*(xp: TxTabsRef; sender: EthAddress) {.inline.} =
  ## Tag `sender` address argument *local*
  xp.byLocal[sender] = true

proc resLocal*(xp: TxTabsRef; sender: EthAddress) {.inline.} =
  ## Untag *local* `sender` address argument.
  xp.byLocal.del(sender)

# ------------------------------------------------------------------------------
# Public iterators, `sender` > `nonce` > `item`
# ------------------------------------------------------------------------------

iterator walkItems*(senderTab: var TxSenderTab): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over item lists grouped by sender addresses with inceasing nonces
  ## per sender.
  var rcAddr = senderTab.first
  while rcAddr.isOK:
    let (addrKey, nonceList) = (rcAddr.value.key, rcAddr.any.value.data)

    var rcNonce = nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
      yield item
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

iterator walkNonceList*(senderTab: var TxSenderTab): TxSenderNonceRef =
  ## Walk over item lists grouped by sender addresses and local/remote. This
  ## iterator stops at the `TxSenderNonceRef` level sub-list.
  var rcAddr = senderTab.first
  while rcAddr.isOK:
    let (addrKey, nonceList) = (rcAddr.value.key, rcAddr.any.value.data)
    yield nonceList

    rcAddr = senderTab.next(addrKey)

iterator walkItems*(nonceList: TxSenderNonceRef;
                    nonce = AccountNonce.low): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Top level part to replace `xp.bySender.walkItems` with:
  ## ::
  ##  for nonceList in xp.bySender.walkNonceList:
  ##    for item in nonceList.walkItems:
  ##      ...
  ##
  var rcNonce = nonceList.ge(nonce)
  while rcNonce.isOk:
    let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
    yield item
    rcNonce = nonceList.gt(nonceKey)

iterator walkItems*(schedList: TxSenderSchedRef;
                    nonce = AccountNonce.low): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Top level part to replace `xp.bySender.walkItem` with:
  ## ::
  ##  for schedList in xp.bySender.walkSchedList:
  ##    for item in schedList.walkItems:
  ##      ...
  ##
  let nonceList = schedList.any.value.data
  var rcNonce = nonceList.ge(nonce)
  while rcNonce.isOk:
    let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
    yield item
    rcNonce = nonceList.gt(nonceKey)

iterator walkItems*(schedList: TxSenderSchedRef;
                    status: TxItemStatus): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = schedList.eq(status)
  if rc.isOK:
    let nonceList = rc.value.data
    var rcNonce = nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
      yield item
      rcNonce = nonceList.gt(nonceKey)

# ------------------------------------------------------------------------------
# Public iterators, `effectiveGasTip` > `nonce` > `item`
# -----------------------------------------------------------------------------

iterator incItemList*(priceTab: var TxPriceTab;
                      minPrice = GasPriceEx.low): TxLeafItemRef =
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
                       minPrice = GasPriceEx.low): TxPriceNonceRef =
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
                      maxPrice = GasPriceEx.high): TxLeafItemRef =
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
                       maxPrice = GasPriceEx.high): TxPriceNonceRef =
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
                      minCap = GasPrice.low): TxLeafItemRef =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## See also the **Note* at the comment for `byTipCap.incItem()`.
  var rc = gasTab.ge(minCap)
  while rc.isOk:
    let gasKey = rc.value.key
    yield rc.value.data
    rc = gasTab.gt(gasKey)

iterator decItemList*(gasTab: var TxTipCapTab;
                      maxCap = GasPrice.high): TxLeafItemRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `byTipCap.incItem()`.
  var rc = gasTab.le(maxCap)
  while rc.isOk:
    let gasKey = rc.value.key
    yield rc.value.data
    rc = gasTab.lt(gasKey)

# ------------------------------------------------------------------------------
# Public iterators, `TxItemStatus` > `item`
# -----------------------------------------------------------------------------

iterator incItemList*(stTab: var TxStatusTab; status: TxItemStatus): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## For given status, walk: `EthAddress` > `AccountNonce` > item
  let rcStatus = stTab.eq(status)
  if rcStatus.isOK:
    var rcAddr = rcStatus.ge(minEthAddress)
    while rcAddr.isOK:
      let (addrKey, nonceData) = (rcAddr.value.key, rcAddr.value.data)

      var rcNonce = nonceData.ge(AccountNonce.low)
      while rcNonce.isOK:
        let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)

        yield item
        rcNonce = nonceData.gt(nonceKey)

      rcAddr = rcStatus.gt(addrKey)

iterator decItemList*(stTab: var TxStatusTab; status: TxItemStatus): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## For given status, walk: `EthAddress` > `AccountNonce` > item
  let rcStatus = stTab.eq(status)
  if rcStatus.isOK:
    var rcAddr = rcStatus.le(maxEthAddress)
    while rcAddr.isOK:
      let (addrKey, nonceData) = (rcAddr.value.key, rcAddr.value.data)

      var rcNonce = nonceData.le(AccountNonce.high)
      while rcNonce.isOK:
        let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)

        yield item
        rcNonce = nonceData.lt(nonceKey)

      rcAddr = rcStatus.lt(addrKey)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: TxTabsRef): Result[void,TxInfo]
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
    let rc = xp.byItemID.verify
    if rc.isErr:
      return err(txInfoVfyItemIdList)
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
      return err(txInfoVfyStatusSenderTotal)

  if xp.byItemID.len != xp.bySender.nItems:
     return err(txInfoVfySenderTotal)

  if xp.byItemID.len != xp.byGasTip.nItems:
     return err(txInfoVfyGasTipTotal)

  if xp.byItemID.len != xp.byTipCap.nItems:
     return err(txInfoVfyTipCapTotal)

  if xp.byItemID.len != xp.byStatus.nItems:
     return err(txInfoVfyStatusTotal)

  # ---------------------

  block:
    let rc = xp.byRejects.txVerify
    if rc.isErr:
      return rc

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
