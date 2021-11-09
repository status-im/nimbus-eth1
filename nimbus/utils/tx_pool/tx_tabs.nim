# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Database For Buckets And Waste Basket
## ======================================================
##

import
  std/[sequtils, tables],
  ./tx_info,
  ./tx_item,
  ./tx_tabs/[tx_leaf, tx_sender, tx_status, tx_tipcap],
  eth/[common, keys],
  stew/[keyed_queue, keyed_queue/kq_debug, results, sorted_set]

{.push raises: [Defect].}

export
  any, eq, first, ge, gt, hasKey, last, le, len, lt,
  nItems, gasLimits, next, prev, walkItems

type
  TxTabsItemsCount* = tuple
    pending, staged, packed: int ## sum => total
    total: int                   ## excluding rejects
    disposed: int                ## waste basket

  TxTabsGasTotals* = tuple
    pending, staged, packed: GasInt ## sum => total

  TxTabsRef* = ref object ##\
    ## Base descriptor
    maxRejects: int ##\
      ## maximal number of items in waste basket

    # ----- primary tables ------

    byLocal*: Table[EthAddress,bool] ##\
      ## List of local accounts

    byRejects*: KeyedQueue[Hash256,TxItemRef] ##\
      ## Rejects queue, waste basket

    byItemID*: KeyedQueue[Hash256,TxItemRef] ##\
      ## Primary table, pending by arrival event

    # ----- index tables ------

    byTipCap*: TxTipCapTab ##\
      ## Index for byItemID: `gasTipCap` > item

    bySender*: TxSenderTab ##\
      ## Index for byItemID: `sender` > `status` > `nonce` > item

    byStatus*: TxStatusTab ##\
      ## Index for byItemID: `status` > `nonce` > item


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

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc deleteImpl(xp: TxTabsRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  if xp.byItemID.delete(item.itemID).isOK:
    xp.byTipCap.txDelete(item)
    discard xp.bySender.txDelete(item)
    discard xp.byStatus.txDelete(item)
    return true

proc insertImpl(xp: TxTabsRef; item: TxItemRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
  if not xp.bySender.txInsert(item):
    return err(txInfoErrSenderNonceIndex)
  discard xp.byItemID.append(item.itemID,item)
  xp.byTipCap.txInsert(item)
  xp.byStatus.txInsert(item)
  return ok()

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxTabsRef): T =
  ## Constructor, returns new tx-pool descriptor.
  new result
  result.maxRejects = txTabMaxRejects

  # result.byLocal -- Table, no need to init
  # result.byItemID -- KeyedQueue, no need to init
  # result.byRejects -- KeyedQueue, no need to init

  # index tables
  result.byTipCap.txInit
  result.bySender.txInit
  result.byStatus.txInit

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(
    xp: TxTabsRef;
    tx: var Transaction;
    status = txItemPending;
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
    let rc = TxItemRef.init(tx, itemID, status, info)
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
  if xp.byRejects.len <= maxItems:
    result[0] = xp.byRejects.len
    xp.byRejects.clear
    return # result
  while result[0] < maxItems:
    if xp.byRejects.shift.isErr:
      break
    result[0].inc
  result[1] = xp.byRejects.len


proc dispose*(xp: TxTabsRef; item: TxItemRef; reason: TxInfo): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Move argument `item` to rejects queue (aka waste basket.)
  if xp.deleteImpl(item):
    if xp.maxRejects <= xp.byRejects.len:
      discard xp.flushRejects(1 + xp.byRejects.len - xp.maxRejects)
    item.reject = reason
    xp.byRejects[item.itemID] = item
    return true

proc reject*(xp: TxTabsRef; tx: var Transaction;
             reason: TxInfo; status = txItemPending; info = "")
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to dispose but for a tx without the item wrapper, the function
  ## imports the tx into the waste basket (e.g. after it could not
  ## be inserted.)
  if xp.maxRejects <= xp.byRejects.len:
    discard xp.flushRejects(1 + xp.byRejects.len - xp.maxRejects)
  let item = TxItemRef.init(tx, reason, status, info)
  xp.byRejects[item.itemID] = item

proc reject*(xp: TxTabsRef; item: TxItemRef; reason: TxInfo)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Variant of `reject()` with `item` rather than `tx` (assuming
  ## `item` is not in the database.)
  if xp.maxRejects <= xp.byRejects.len:
    discard xp.flushRejects(1 + xp.byRejects.len - xp.maxRejects)
  item.reject = reason
  xp.byRejects[item.itemID] = item

proc reject*(xp: TxTabsRef; tx: Transaction;
             reason: TxInfo; status = txItemPending; info = "")
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Variant of `reject()`
  var ty = tx
  xp.reject(ty, reason, status)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc maxRejects*(xp: TxTabsRef): int =
  ## Getter
  xp.maxRejects

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `maxRejects=`*(xp: TxTabsRef; val: int) =
  ## Setter, applicable with next `reject()` invocation.
  xp.maxRejects = val

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

proc hasTx*(xp: TxTabsRef; tx: Transaction): bool =
  ## Returns `true` if the argument pair `(key,local)` exists in the
  ## database.
  ##
  ## If this function returns `true`, then it is save to use the `xp[key]`
  ## paradigm for accessing a transaction container.
  xp.byItemID.hasKey(tx.itemID)

proc nItems*(xp: TxTabsRef): TxTabsItemsCount
    {.gcsafe,raises: [Defect,KeyError].} =
  result.pending = xp.byStatus.eq(txItemPending).nItems
  result.staged = xp.byStatus.eq(txItemStaged).nItems
  result.packed = xp.byStatus.eq(txItemPacked).nItems
  result.total =  xp.byItemID.len
  result.disposed = xp.byRejects.len

proc gasTotals*(xp: TxTabsRef): TxTabsGasTotals
    {.gcsafe,raises: [Defect,KeyError].} =
  result.pending = xp.byStatus.eq(txItemPending).gasLimits
  result.staged = xp.byStatus.eq(txItemStaged).gasLimits
  result.packed = xp.byStatus.eq(txItemPacked).gasLimits

# ------------------------------------------------------------------------------
# Public functions: local/remote sender accounts
# ------------------------------------------------------------------------------

proc isLocal*(xp: TxTabsRef; sender: EthAddress): bool =
  ## Returns `true` if account address is local
  xp.byLocal.hasKey(sender)

proc locals*(xp: TxTabsRef): seq[EthAddress] =
  ## Returns  an unsorted list of addresses tagged *local*
  toSeq(xp.byLocal.keys)

proc remotes*(xp: TxTabsRef): seq[EthAddress] =
  ## Returns  an unsorted list of untagged addresses
  var rcAddr = xp.bySender.first
  while rcAddr.isOK:
    let sender = rcAddr.value.key
    rcAddr = xp.bySender.next(sender)
    if not xp.byLocal.hasKey(sender):
      result.add sender

proc setLocal*(xp: TxTabsRef; sender: EthAddress) =
  ## Tag `sender` address argument *local*
  xp.byLocal[sender] = true

proc resLocal*(xp: TxTabsRef; sender: EthAddress) =
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

iterator walkAccountPair*(stTab: var TxStatusTab; status: TxItemStatus):
         (EthAddress,TxStatusNonceRef) {.gcsafe,raises: [Defect,KeyError].} =
  ## For given status, walk: `EthAddress` > (sender,nonceList)
  let rcBucket = stTab.eq(status)
  if rcBucket.isOK:
    var rcAcc = rcBucket.ge(minEthAddress)
    while rcAcc.isOK:
      let (sender, nonceList) = (rcAcc.value.key, rcAcc.value.data)
      yield (sender, nonceList)
      rcAcc = rcBucket.gt(sender) # potenially modified database

iterator incItemList*(nonceList: TxStatusNonceRef;
                      nonceFrom = AccountNonce.low): TxItemRef =
  ## For given nonce list, visit all items with increasing nonce order.
  var rc = nonceList.ge(nonceFrom)
  while rc.isOK:
    let (nonceKey, item) = (rc.value.key, rc.value.data)
    yield item
    rc = nonceList.gt(nonceKey) # potenially modified database


iterator incItemList*(stTab: var TxStatusTab; status: TxItemStatus): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## For given status, walk: `EthAddress` > `AccountNonce` > item
  let rcStatus = stTab.eq(status)
  if rcStatus.isOK:
    var rcAddr = rcStatus.ge(minEthAddress)
    while rcAddr.isOK:
      let (addrKey, nonceList) = (rcAddr.value.key, rcAddr.value.data)

      var rcNonce = nonceList.ge(AccountNonce.low)
      while rcNonce.isOK:
        let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
        yield item
        rcNonce = nonceList.gt(nonceKey) # potenially modified database

      rcAddr = rcStatus.gt(addrKey)      # potenially modified database

iterator decItemList*(stTab: var TxStatusTab; status: TxItemStatus): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## For given status, walk: `EthAddress` > `AccountNonce` > item
  let rcStatus = stTab.eq(status)
  if rcStatus.isOK:
    var rcAddr = rcStatus.le(maxEthAddress)
    while rcAddr.isOK:
      let (addrKey, nonceList) = (rcAddr.value.key, rcAddr.value.data)

      var rcNonce = nonceList.le(AccountNonce.high)
      while rcNonce.isOK:
        let (nonceKey, item) = (rcNonce.value.key, rcNonce.value.data)
        yield item
        rcNonce = nonceList.lt(nonceKey)   # potenially modified database

      rcAddr = rcStatus.lt(addrKey)        # potenially modified database

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: TxTabsRef): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
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
    let rc = xp.byRejects.verify
    if rc.isErr:
      return err(txInfoVfyRejectsList)
  block:
    let rc = xp.byStatus.txVerify
    if rc.isErr:
      return rc

  for status in TxItemStatus:
    var
      statusCount = 0
      statusAllGas = 0.GasInt
      rcAddr = xp.bySender.first
    while rcAddr.isOk:
      let (addrKey, schedData) = (rcAddr.value.key, rcAddr.value.data)
      rcAddr = xp.bySender.next(addrKey)
      statusCount += schedData.eq(status).nItems
      statusAllGas += schedData.eq(status).gasLimits

    if xp.byStatus.eq(status).nItems != statusCount:
      return err(txInfoVfyStatusSenderTotal)
    if xp.byStatus.eq(status).gasLimits != statusAllGas:
      return err(txInfoVfyStatusSenderGasLimits)

  if xp.byItemID.len != xp.bySender.nItems:
     return err(txInfoVfySenderTotal)

  if xp.byItemID.len != xp.byTipCap.nItems:
     return err(txInfoVfyTipCapTotal)

  if xp.byItemID.len != xp.byStatus.nItems:
     return err(txInfoVfyStatusTotal)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
