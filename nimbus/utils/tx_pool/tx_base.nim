# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Descriptor
## ===========================

import
  std/[algorithm, sequtils],
  ../keequ,
  ../slst,
  ./tx_list,
  ./tx_queue,
  ./tx_tab,
  ./tx_item,
  eth/[common, keys],
  stew/results

type
  TxBaseInfo* = enum ##\
    ## Error codes (as used in verification function.)
    txOk = 0

    txVfyByIdQueueList       ## Corrupted ID queue/fifo structure
    txVfyByIdQueueKey        ## Corrupted ID queue/fifo container id
    txVfyByIdQueueSchedule   ## Local flag indicates wrong schedule

    txVfyByGasPriceList      ## Corrupted gas price list structure
    txVfyByGasPriceLeafEmpty ## Empty gas price list leaf record
    txVfyByGasPriceLeafQueue ## Corrupted gas price leaf queue
    txVfyByGasPriceTotal     ## Wrong number of leaves

    txVfyBySenderLeafEmpty   ## Empty sender list leaf record
    txVfyBySenderLeafQueue   ## Corrupted sender leaf queue
    txVfyBySenderTotal       ## Wrong number of leaves


  TxPoolBase* = object of RootObj ##\
    ## Base descriptor
    byIdQueue*: TxQueue       ## Primary table, queued by arrival event
    byGasPrice*: TxGasItemLst ## Indexed by gas price
    bySender*: TxAddrTab      ## Grouped by sender addresses

const
  TxQueueScheduleReversed =
    toSeq(TxQueueSchedule).reversed

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

method init*(xp: var TxPoolBase) {.base.} =
  ## Constructor, returns new tx-pool descriptor.
  xp.byIdQueue.txInit
  xp.byGasPrice.txInit
  # no initialisation needed for bySender

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(tx: Transaction): Hash256 {.inline.} =
  ## Transaction hash serves as ID
  tx.rlpHash

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(xp: var TxPoolBase;
             tx: var Transaction; local = true; info = ""): Result[Hash256,void]
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
  let key = tx.hash
  if not xp.byIdQueue.hasKey(key):
    let rc = tx.newTxItemRef(key, local, info)
    if rc.isOK:
      let item = rc.value
      xp.byIdQueue.txAppend(key, local.toQueueSched, item)
      xp.byGasPrice.txInsert(item.tx.gasPrice, item)
      xp.bySender.txInsert(item.sender, item)
      return ok(key)
  err()


proc insert*(xp: var TxPoolBase;
             tx: Transaction; local = true; info = ""): auto
    {.inline, gcsafe,raises: [Defect,CatchableError].} =
  ## Variant of `insert()` for call-by-value transaction
  var ty = tx
  xp.insert(ty,local,info)


proc reassign*(xp: var TxPoolBase;
               key: Hash256; local: bool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Reassign transaction local/remote flag of a database entry. The function
  ## succeeds returning the wrapping transaction container if the transaction
  ## was found with a different local/remote flag than the argument `local`
  ## and subsequently was changed.
  let
    sched = (not local).toQueueSched
    rc = xp.byIdQueue.eq(key, sched)
  if rc.isOK:
    let item = rc.value
    if item.local != local:
      # append will auto-delete any existing entry of the other queue
      xp.byIdQueue.txAppend(key, local.toQueueSched, item)
      return ok(item)
  err()


proc delete*(xp: var TxPoolBase;
             key: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  for sched in TxQueueSchedule:
    let rc = xp.byIdQueue.txDelete(key, sched)
    if rc.isOK:
      let item = rc.value
      xp.byGasPrice.txDelete(item.tx.gasPrice, item)
      xp.bySender.txDelete(item.sender, item)
      return ok(item)
  err()

proc delete*(xp: var TxPoolBase;
             item: TxItemRef): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Variant of `delete()`
  let rc = xp.byIdQueue.txDelete(item.id, item.local.toQueueSched)
  if rc.isOK:
    let item = rc.value
    xp.byGasPrice.txDelete(item.tx.gasPrice, item)
    xp.bySender.txDelete(item.sender, item)
    return ok(item)
  err()

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(xp: var TxPoolBase): int =
  ## Total number of registered transactions
  xp.byIdQueue.nLeaves

proc len*(rq: var TxListItems): int =
  ## Returns the number of items on the argument queue `rq` which is typically
  ## the result of an `SLstRef` type object query holding one or more
  ## duplicates relative to the same index.
  keequ.len(rq)

proc byLocalQueueLen*(xp: var TxPoolBase): int =
  ## Number of transactions in local queue
  xp.byIdQueue.len(TxLocalQueue)

proc byRemoteQueueLen*(xp: var TxPoolBase): int =
  ## Number of transactions in local queue
  xp.byIdQueue.len(TxRemoteQueue)

proc byGasPriceLen*(xp: var TxPoolBase): int =
  ## Number of different gas prices known. For each gas price there is at least
  ## one transaction available.
  xp.byGasPrice.len

proc bySenderLen*(xp: var TxPoolBase): int =
  ## Number of different sendeer adresses known. For each address there is at
  ## least one transaction available.
  xp.bySender.len

# ------------------------------------------------------------------------------
# Public functions, ID queue query
# ------------------------------------------------------------------------------

proc hasKey*(xp: var TxPoolBase; key: Hash256): bool =
  ## Returns `true` if the argument `key` for a transaction exists in the
  ## database, already. If this function returns `true`, then it is save to
  ## use the `xp[key]` paradigm for accessing a transaction container.
  xp.byIdQueue.hasKey(key, true.toQueuesched) or
    xp.byIdQueue.hasKey(key, false.toQueuesched)

proc toKey*(tx: Transaction): Hash256 {.inline.} =
  ## Retrieves transaction key. Note that the returned argument will only apply
  ## to a transaction in the database if the argument transaction `tx` is
  ## exactly the same as the one passed earlier to the `insert()` function.
  tx.hash

proc `[]`*(xp: var TxPoolBase; key: Hash256): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## If it exists, this function retrieves a transaction container `item`
  ## for the argument `key` with
  ## ::
  ##   item.id == key
  ##
  ## See also commments on `toKey()` and `insert()`.
  ##
  ## Note that the function returns `nil` unless the argument `key` exists
  ## in the database which shiulld be avoided using `hasKey()`.
  block:
    let rc = xp.byIdQueue.eq(key, true.toQueuesched)
    if rc.isOK:
      return rc.value
  block:
    let rc = xp.byIdQueue.eq(key, false.toQueuesched)
    if rc.isOK:
      return rc.value


proc first*(xp: var TxPoolBase; local: bool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc =  xp.byIdQueue.first(local.toQueuesched)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc last*(xp: var TxPoolBase; local: bool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.last(local.toQueuesched)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc next*(xp: var TxPoolBase;
           key: Hash256; local: bool): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.next(local.toQueuesched, key)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc prev*(xp: var TxPoolBase;
           key: Hash256; local: bool): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.prev(local.toQueuesched, key)
  if rc.isOK:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, gas price query
# ------------------------------------------------------------------------------

proc byGasPriceGe*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItems,void] =
  ## Retrieve the list of transaction records all with the same *least* gas
  ## price *greater or equal* the argument `gWei`. On success, the resulting
  ## list of transactions has at least one item.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  let rc = xp.byGasPrice.ge(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceGt*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.gt(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceLe*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.le(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceLt*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.lt(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasPriceEq*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItems,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.eq(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, sender query
# ------------------------------------------------------------------------------

proc bySenderEq*(xp: var TxPoolBase;
                 ethAddr: EthAddress): Result[TxListItems,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Similar to `byGasPriceGe()`.
  if xp.bySender.hasKey(ethAddr):
    return ok(xp.bySender[ethAddr])
  err()

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator firstOutItems*(xp: var TxPoolBase): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## ID queue walk/traversal: oldest first (fifo).
  ##
  ## Note: When running in a loop it is ok to delete the current item and
  ## the all items already visited. Items not visited yet must not be deleted.
  for sched in TxQueueSchedule:
    var rc = xp.byIdQueue.first(sched)
    while rc.isOK:
      let (key,data) = (rc.value.key, rc.value.data)
      rc = xp.byIdQueue.next(sched,key)
      yield data

iterator lastInItems*(xp: var TxPoolBase): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## ID queue walk/traversal: newest first (lifo)
  ##
  ## Note: When running in a loop it is ok to delete the current item and
  ## the all items already visited. Items not visited yet must not be deleted.
  for sched in TxQueueScheduleReversed:
    var rc = xp.byIdQueue.last(sched)
    while rc.isOK:
      let (key,data) = (rc.value.key, rc.value.data)
      rc = xp.byIdQueue.prev(sched, key)
      yield data

iterator byGasPriceIncPairs*(xp: var TxPoolBase;
                             fromGe = GasInt.low): (GasInt,var TxListItems) =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  ##
  ## Note: When running in a loop it is ok to add or delete any entries,
  ## visited or not visited yet. So, deleting all entries with gas prices
  ## greater or equal than `delMin` would look like:
  ## ::
  ##  for _, txList in xp.byGasPriceIncPairs(fromGe = delMin):
  ##    for tx in txList.nextKeys:
  ##      discard xq.delete(tx)
  ##
  var rc = xp.byGasPrice.ge(fromGe)
  while rc.isOk:
    let yKey = rc.value.key
    yield (ykey, rc.value.data)
    rc = xp.byGasPrice.gt(ykey)

iterator byGasPriceDecPairs*(xp: var TxPoolBase;
                             fromLe = GasInt.high): (GasInt,var TxListItems) =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  ##
  ## Note: When running in a loop it is ok to add or delete any entries,
  ## vistied or not visited yet. So, deleting all entries with gas prices
  ## less or equal than `delMax` would look like:
  ## ::
  ##  for _, txList in xp.byGasPriceDecPairs(fromLe = delMax):
  ##    for tx in txList.nextKeys:
  ##      discard xq.delete(tx)
  ##
  var rc = xp.byGasPrice.le(fromLe)
  while rc.isOk:
    let yKey = rc.value.key
    yield (yKey, rc.value.data)
    rc = xp.byGasPrice.lt(yKey)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: var TxPoolBase): Result[void,TxBaseInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.byGasPrice.txVerify
    if rc.isErr:
      case rc.error[0]
      of txListOk:           return err(txOk)
      of txListVfyRbTree:    return err(txVfyByGasPriceList)
      of txListVfyLeafEmpty: return err(txVfyByGasPriceLeafEmpty)
      of txListVfyLeafQueue: return err(txVfyByGasPriceLeafQueue)
      of txListVfySize:      return err(txVfyByGasPriceTotal)
  block:
    let rc = xp.bySender.txVerify
    if rc.isErr:
      case rc.error[0]
      of txTabOk:            return err(txOk)
      of txTabVfyLeafEmpty:  return err(txVfyBySenderLeafEmpty)
      of txTabVfyLeafQueue:  return err(txVfyBySenderLeafQueue)
      of txTabVfySize:       return err(txVfyBySenderTotal)
  block:
    let rc = xp.byIdQueue.txVerify
    if rc.isErr:
      case rc.error[0]
      of txQuOk:             return err(txOk)
      of txQuVfyQueueList:   return err(txVfyByIdQueueList)
      of txQuVfyQueueKey:    return err(txVfyByIdQueueKey)
      of txQuVfySchedule:    return err(txVfyByIdQueueSchedule)

  if xp.len != xp.byIdQueue.nLeaves:
     return err(txVfyByGasPriceTotal)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
