# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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

{.push raises: [].}

import
  std/[sequtils, tables],
  ./tx_info,
  ./tx_item,
  ./tx_tabs/[tx_sender, tx_rank, tx_status],
  eth/[common, keys],
  stew/[keyed_queue, keyed_queue/kq_debug, sorted_set],
  results

export
  # bySender/byStatus index operations
  sub,
  eq,
  ge,
  gt,
  le,
  len,
  lt,
  nItems,
  gasLimits

type
  TxTabsItemsCount* =
    tuple
      pending, staged, packed: int ## sum => total
      total: int ## excluding rejects
      disposed: int ## waste basket

  TxTabsGasTotals* =
    tuple
      pending, staged, packed: GasInt ## sum => total

  TxTabsLocality* = object
    ##\
    ## Return value for `locality()` function
    local: seq[EthAddress]
      ##\
      ## List of local accounts, higest rank first

    remote: seq[EthAddress]
      ##\
      ## List of non-local accounts, higest rank first

  TxTabsRef* = ref object
    ##\
    ## Base descriptor
    maxRejects: int
      ##\
      ## Maximal number of items in waste basket

    # ----- primary tables ------
    byLocal*: Table[EthAddress, bool]
      ##\
      ## List of local accounts (currently idle/unused)

    byRejects*: KeyedQueue[Hash256, TxItemRef]
      ##\
      ## Rejects queue and waste basket, queued by disposal event

    byItemID*: KeyedQueue[Hash256, TxItemRef]
      ##\
      ## Primary table containing all tx items, queued by arrival event

    # ----- index tables for byItemID ------
    bySender*: TxSenderTab
      ##\
      ## Index for byItemID: `sender` > `status` > `nonce` > item

    byStatus*: TxStatusTab
      ##\
      ## Index for byItemID: `status` > `nonce` > item

    byRank*: TxRankTab
      ##\
      ## Ranked address table, used for sender address traversal

const txTabMaxRejects = ##\
  ## Default size of rejects queue (aka waste basket.) Older waste items will
  ## be automatically removed so that there are no more than this many items
  ## in the rejects queue.
  500

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc deleteImpl(xp: TxTabsRef, item: TxItemRef): bool {.gcsafe, raises: [KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  if xp.byItemID.delete(item.itemID).isOk:
    discard xp.bySender.delete(item)
    discard xp.byStatus.delete(item)

    # Update address rank
    let rc = xp.bySender.rank(item.sender)
    if rc.isOk:
      discard xp.byRank.insert(rc.value.TxRank, item.sender) # update
    else:
      discard xp.byRank.delete(item.sender)

    return true

proc insertImpl(
    xp: TxTabsRef, item: TxItemRef
): Result[void, TxInfo] {.gcsafe, raises: [CatchableError].} =
  if not xp.bySender.insert(item):
    return err(txInfoErrSenderNonceIndex)

  # Insert item
  discard xp.byItemID.append(item.itemID, item)
  discard xp.byStatus.insert(item)

  # Update address rank
  let rank = xp.bySender.rank(item.sender).value.TxRank
  discard xp.byRank.insert(rank, item.sender)

  return ok()

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc new*(T: type TxTabsRef): T {.gcsafe, raises: [].} =
  ## Constructor, returns new tx-pool descriptor.
  new result
  result.maxRejects = txTabMaxRejects

  # result.byLocal -- Table, no need to init
  # result.byItemID -- KeyedQueue, no need to init
  # result.byRejects -- KeyedQueue, no need to init

  # index tables
  result.bySender.init
  result.byStatus.init
  result.byRank.init

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(
    xp: TxTabsRef, tx: var PooledTransaction, status = txItemPending, info = ""
): Result[void, TxInfo] {.gcsafe, raises: [CatchableError].} =
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
    let rc = TxItemRef.new(tx, itemID, status, info)
    if rc.isErr:
      return err(txInfoErrInvalidSender)
    item = rc.value
  block:
    let rc = xp.insertImpl(item)
    if rc.isErr:
      return rc
  ok()

proc insert*(
    xp: TxTabsRef, item: TxItemRef
): Result[void, TxInfo] {.gcsafe, raises: [CatchableError].} =
  ## Variant of `insert()` with fully qualified `item` argument.
  if xp.byItemID.hasKey(item.itemID):
    return err(txInfoErrAlreadyKnown)
  return xp.insertImpl(item.dup)

proc reassign*(
    xp: TxTabsRef, item: TxItemRef, status: TxItemStatus
): bool {.gcsafe, raises: [CatchableError].} =
  ## Variant of `reassign()` for the `TxItemStatus` flag.
  # make sure that the argument `item` is not some copy
  let rc = xp.byItemID.eq(item.itemID)
  if rc.isOk:
    var realItem = rc.value
    if realItem.status != status:
      discard xp.bySender.delete(realItem) # delete original
      discard xp.byStatus.delete(realItem)
      realItem.status = status
      discard xp.bySender.insert(realItem) # re-insert changed
      discard xp.byStatus.insert(realItem)
      return true

proc flushRejects*(xp: TxTabsRef, maxItems = int.high): (int, int) =
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

proc dispose*(
    xp: TxTabsRef, item: TxItemRef, reason: TxInfo
): bool {.gcsafe, raises: [KeyError].} =
  ## Move argument `item` to rejects queue (aka waste basket.)
  if xp.deleteImpl(item):
    if xp.maxRejects <= xp.byRejects.len:
      discard xp.flushRejects(1 + xp.byRejects.len - xp.maxRejects)
    item.reject = reason
    xp.byRejects[item.itemID] = item
    return true

proc reject*(
    xp: TxTabsRef,
    tx: var PooledTransaction,
    reason: TxInfo,
    status = txItemPending,
    info = "",
) =
  ## Similar to dispose but for a tx without the item wrapper, the function
  ## imports the tx into the waste basket (e.g. after it could not
  ## be inserted.)
  if xp.maxRejects <= xp.byRejects.len:
    discard xp.flushRejects(1 + xp.byRejects.len - xp.maxRejects)
  let item = TxItemRef.new(tx, reason, status, info)
  xp.byRejects[item.itemID] = item

proc reject*(xp: TxTabsRef, item: TxItemRef, reason: TxInfo) =
  ## Variant of `reject()` with `item` rather than `tx` (assuming
  ## `item` is not in the database.)
  if xp.maxRejects <= xp.byRejects.len:
    discard xp.flushRejects(1 + xp.byRejects.len - xp.maxRejects)
  item.reject = reason
  xp.byRejects[item.itemID] = item

proc reject*(
    xp: TxTabsRef,
    tx: PooledTransaction,
    reason: TxInfo,
    status = txItemPending,
    info = "",
) =
  ## Variant of `reject()`
  var ty = tx
  xp.reject(ty, reason, status)

# ------------------------------------------------------------------------------
# Public getters
# ------------------------------------------------------------------------------

proc baseFee*(xp: TxTabsRef): GasInt =
  ## Getter
  xp.bySender.baseFee

proc maxRejects*(xp: TxTabsRef): int =
  ## Getter
  xp.maxRejects

proc local*(lc: TxTabsLocality): seq[EthAddress] =
  ## Getter
  lc.local

proc remote*(lc: TxTabsLocality): seq[EthAddress] =
  ## Getter
  lc.remote

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(xp: TxTabsRef, val: GasInt) {.gcsafe, raises: [KeyError].} =
  ## Setter, update may cause database re-org
  if xp.bySender.baseFee != val:
    xp.bySender.baseFee = val
    # Build new rank table
    xp.byRank.clear
    for (address, rank) in xp.bySender.accounts:
      discard xp.byRank.insert(rank.TxRank, address)

proc `maxRejects=`*(xp: TxTabsRef, val: int) =
  ## Setter, applicable with next `reject()` invocation.
  xp.maxRejects = val

# ------------------------------------------------------------------------------
# Public functions, miscellaneous
# ------------------------------------------------------------------------------

proc hasTx*(xp: TxTabsRef, tx: Transaction): bool =
  ## Returns `true` if the argument pair `(key,local)` exists in the
  ## database.
  ##
  ## If this function returns `true`, then it is save to use the `xp[key]`
  ## paradigm for accessing a transaction container.
  xp.byItemID.hasKey(tx.itemID)

proc nItems*(xp: TxTabsRef): TxTabsItemsCount =
  result.pending = xp.byStatus.eq(txItemPending).nItems
  result.staged = xp.byStatus.eq(txItemStaged).nItems
  result.packed = xp.byStatus.eq(txItemPacked).nItems
  result.total = xp.byItemID.len
  result.disposed = xp.byRejects.len

proc gasTotals*(xp: TxTabsRef): TxTabsGasTotals =
  result.pending = xp.byStatus.eq(txItemPending).gasLimits
  result.staged = xp.byStatus.eq(txItemStaged).gasLimits
  result.packed = xp.byStatus.eq(txItemPacked).gasLimits

# ------------------------------------------------------------------------------
# Public functions: local/remote sender accounts
# ------------------------------------------------------------------------------

proc isLocal*(xp: TxTabsRef, sender: EthAddress): bool =
  ## Returns `true` if account address is local
  xp.byLocal.hasKey(sender)

proc locals*(xp: TxTabsRef): seq[EthAddress] =
  ## Returns  an unsorted list of addresses tagged *local*
  toSeq(xp.byLocal.keys)

proc locality*(xp: TxTabsRef): TxTabsLocality =
  ## Returns a pair of sorted lists of account addresses,
  ## highest address rank first
  var rcRank = xp.byRank.le(TxRank.high)
  while rcRank.isOk:
    let (rank, addrList) = (rcRank.value.key, rcRank.value.data)
    for account in addrList.keys:
      if xp.byLocal.hasKey(account):
        result.local.add account
      else:
        result.remote.add account
    rcRank = xp.byRank.lt(rank)

proc setLocal*(xp: TxTabsRef, sender: EthAddress) =
  ## Tag `sender` address argument *local*
  xp.byLocal[sender] = true

proc resLocal*(xp: TxTabsRef, sender: EthAddress) =
  ## Untag *local* `sender` address argument.
  xp.byLocal.del(sender)

proc flushLocals*(xp: TxTabsRef) =
  ## Untag all *local* addresses on the system.
  xp.byLocal.clear

# ------------------------------------------------------------------------------
# Public iterators, `TxRank` > `(EthAddress,TxStatusNonceRef)`
# ------------------------------------------------------------------------------

iterator incAccount*(
    xp: TxTabsRef, bucket: TxItemStatus, fromRank = TxRank.low
): (EthAddress, TxStatusNonceRef) {.gcsafe, raises: [KeyError].} =
  ## Walk accounts with increasing ranks and return a nonce-ordered item list.
  let rcBucket = xp.byStatus.eq(bucket)
  if rcBucket.isOk:
    let bucketList = xp.byStatus.eq(bucket).value.data

    var rcRank = xp.byRank.ge(fromRank)
    while rcRank.isOk:
      let (rank, addrList) = (rcRank.value.key, rcRank.value.data)

      # Use adresses for this rank which are also found in the bucket
      for account in addrList.keys:
        let rcAccount = bucketList.eq(account)
        if rcAccount.isOk:
          yield (account, rcAccount.value.data)

      # Get next ranked address list (top down index walk)
      rcRank = xp.byRank.gt(rank) # potenially modified database

iterator decAccount*(
    xp: TxTabsRef, bucket: TxItemStatus, fromRank = TxRank.high
): (EthAddress, TxStatusNonceRef) {.gcsafe, raises: [KeyError].} =
  ## Walk accounts with decreasing ranks and return the nonce-ordered item list.
  let rcBucket = xp.byStatus.eq(bucket)
  if rcBucket.isOk:
    let bucketList = xp.byStatus.eq(bucket).value.data

    var rcRank = xp.byRank.le(fromRank)
    while rcRank.isOk:
      let (rank, addrList) = (rcRank.value.key, rcRank.value.data)

      # Use adresses for this rank which are also found in the bucket
      for account in addrList.keys:
        let rcAccount = bucketList.eq(account)
        if rcAccount.isOk:
          yield (account, rcAccount.value.data)

      # Get next ranked address list (top down index walk)
      rcRank = xp.byRank.lt(rank) # potenially modified database

iterator packingOrderAccounts*(
    xp: TxTabsRef, bucket: TxItemStatus
): (EthAddress, TxStatusNonceRef) {.gcsafe, raises: [KeyError].} =
  ## Loop over accounts from a particular bucket ordered by
  ## + local ranks, higest one first
  ## + remote ranks, higest one first
  ## For the `txItemStaged` bucket, this iterator defines the packing order
  ## for transactions (important when calculationg the *txRoot*.)
  for (account, nonceList) in xp.decAccount(bucket):
    if xp.isLocal(account):
      yield (account, nonceList)
  for (account, nonceList) in xp.decAccount(bucket):
    if not xp.isLocal(account):
      yield (account, nonceList)

# ------------------------------------------------------------------------------
# Public iterators, `TxRank` > `(EthAddress,TxSenderNonceRef)`
# ------------------------------------------------------------------------------

iterator incAccount*(
    xp: TxTabsRef, fromRank = TxRank.low
): (EthAddress, TxSenderNonceRef) {.gcsafe, raises: [KeyError].} =
  ## Variant of `incAccount()` without bucket restriction.
  var rcRank = xp.byRank.ge(fromRank)
  while rcRank.isOk:
    let (rank, addrList) = (rcRank.value.key, rcRank.value.data)

    # Try all sender adresses found
    for account in addrList.keys:
      yield (account, xp.bySender.eq(account).sub.value.data)

    # Get next ranked address list (top down index walk)
    rcRank = xp.byRank.gt(rank) # potenially modified database

iterator decAccount*(
    xp: TxTabsRef, fromRank = TxRank.high
): (EthAddress, TxSenderNonceRef) {.gcsafe, raises: [KeyError].} =
  ## Variant of `decAccount()` without bucket restriction.
  var rcRank = xp.byRank.le(fromRank)
  while rcRank.isOk:
    let (rank, addrList) = (rcRank.value.key, rcRank.value.data)

    # Try all sender adresses found
    for account in addrList.keys:
      yield (account, xp.bySender.eq(account).sub.value.data)

    # Get next ranked address list (top down index walk)
    rcRank = xp.byRank.lt(rank) # potenially modified database

# -----------------------------------------------------------------------------
# Public second stage iterators: nonce-ordered item lists.
# -----------------------------------------------------------------------------

iterator incNonce*(
    nonceList: TxSenderNonceRef, nonceFrom = AccountNonce.low
): TxItemRef =
  ## Second stage iterator inside `incAccount()` or `decAccount()`. The
  ## items visited are always sorted by least-nonce first.
  var rc = nonceList.ge(nonceFrom)
  while rc.isOk:
    let (nonce, item) = (rc.value.key, rc.value.data)
    yield item
    rc = nonceList.gt(nonce) # potenially modified database

iterator incNonce*(
    nonceList: TxStatusNonceRef, nonceFrom = AccountNonce.low
): TxItemRef =
  ## Variant of `incNonce()` for the `TxStatusNonceRef` list.
  var rc = nonceList.ge(nonceFrom)
  while rc.isOk:
    let (nonce, item) = (rc.value.key, rc.value.data)
    yield item
    rc = nonceList.gt(nonce) # potenially modified database

#[
# There is currently no use for nonce count down traversal

iterator decNonce*(nonceList: TxSenderNonceRef;
                   nonceFrom = AccountNonce.high): TxItemRef
    {.gcsafe, raises: [KeyError].} =
  ## Similar to `incNonce()` but visiting items in reverse order.
  var rc = nonceList.le(nonceFrom)
  while rc.isOk:
    let (nonce, item) = (rc.value.key, rc.value.data)
    yield item
    rc = nonceList.lt(nonce) # potenially modified database


iterator decNonce*(nonceList: TxStatusNonceRef;
                   nonceFrom = AccountNonce.high): TxItemRef =
  ## Variant of `decNonce()` for the `TxStatusNonceRef` list.
  var rc = nonceList.le(nonceFrom)
  while rc.isOk:
    let (nonce, item) = (rc.value.key, rc.value.data)
    yield item
    rc = nonceList.lt(nonce) # potenially modified database
]#

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: TxTabsRef): Result[void, TxInfo] {.gcsafe, raises: [CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.bySender.verify
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
    let rc = xp.byStatus.verify
    if rc.isErr:
      return rc
  block:
    let rc = xp.byRank.verify
    if rc.isErr:
      return rc

  for status in TxItemStatus:
    var
      statusCount = 0
      statusAllGas = 0.GasInt
    for (account, nonceList) in xp.incAccount(status):
      let bySenderStatusList = xp.bySender.eq(account).eq(status)
      statusAllGas += bySenderStatusList.gasLimits
      statusCount += bySenderStatusList.nItems
      if bySenderStatusList.nItems != nonceList.nItems:
        return err(txInfoVfyStatusSenderTotal)

    if xp.byStatus.eq(status).nItems != statusCount:
      return err(txInfoVfyStatusSenderTotal)
    if xp.byStatus.eq(status).gasLimits != statusAllGas:
      return err(txInfoVfyStatusSenderGasLimits)

  if xp.byItemID.len != xp.bySender.nItems:
    return err(txInfoVfySenderTotal)

  if xp.byItemID.len != xp.byStatus.nItems:
    return err(txInfoVfyStatusTotal)

  if xp.bySender.len != xp.byRank.nItems:
    return err(txInfoVfyRankTotal)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
