# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Basig Primitives
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
  ./tx_group,
  ./tx_item,
  ./tx_jobs,
  ./tx_list,
  ./tx_nonce,
  ./tx_price,
  ./tx_queue,
  eth/[common, keys],
  stew/results

type
  TxBaseInfo* = enum ##\
    ## Error codes (as used in verification function.)
    txOk = 0

    txVfyByJobsQueue          ## Corrupted jobs queue/fifo structure

    txVfyByIdQueueList        ## Corrupted ID queue/fifo structure
    txVfyByIdQueueKey         ## Corrupted ID queue/fifo container id
    txVfyByIdQueueSchedule    ## Local flag indicates wrong schedule

    txVfyBySenderQueue        ## Corrupted sender queue/table structure
    txVfyBySenderLeafEmpty    ## Empty sender list leaf record
    txVfyBySenderLeafQueue    ## Corrupted sender leaf queue
    txVfyBySenderTotal        ## Wrong number of leaves

    txVfyByNonceList          ## Corrupted nonce list structure
    txVfyByNonceLeafEmpty     ## Empty nonce list leaf record
    txVfyByNonceLeafQueue     ## Corrupted nonce leaf queue
    txVfyByNonceTotal         ## Wrong number of leaves

    txVfyByPriceList          ## Corrupted gas price list structure
    txVfyByPriceLeafEmpty     ## Empty gas price list leaf record
    txVfyByPriceLeafQueue     ## Corrupted gas price leaf queue
    txVfyByPriceTotal         ## Wrong number of leaves

    txVfyByGasTipCapList      ## Corrupted gas price list structure
    txVfyByGasTipCapLeafEmpty ## Empty gas price list leaf record
    txVfyByGasTipCapLeafQueue ## Corrupted gas price leaf queue
    txVfyByGasTipCapTotal     ## Wrong number of leaves

    txBaseErrAlreadyKnown
    txBaseErrInvalidSender


  TxPoolBase* = object of RootObj ##\
    ## Base descriptor
    byIdQueue*: TxQueue          ## Primary table, queued by arrival event
    byPriceNonce*: TxPriceItems  ## Indexed by `gasPrice` > `nonce`
    byNoncePrice*: TxNonceItems  ## Indexed by `nonce` > `gasPrice`
    byGasTipCap*: TxGasItemLst   ## Indexed by `maxPriorityFee`
    bySender*: TxGroupAddr       ## Indexed by `sender` > `local`
    byJobs*: TxJobs              ## Jobs batch list

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

method init*(xp: var TxPoolBase) {.base.} =
  ## Constructor, returns new tx-pool descriptor.
  xp.byIdQueue.txInit
  xp.byPriceNonce.txInit
  xp.byNoncePrice.txInit
  xp.byGasTipCap.txInit
  xp.bySender.txInit
  xp.byJobs.txInit

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
             tx: var Transaction; local = true; info = ""):
               Result[void,TxBaseInfo]
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
  let itemID = tx.hash
  if xp.byIdQueue.hasItemID(itemID):
    return err(txBaseErrAlreadyKnown)
  let rc = tx.newTxItemRef(itemID, local, info)
  if rc.isErr:
    return err(txBaseErrInvalidSender)
  let item = rc.value
  xp.byIdQueue.txAppend(item)
  xp.byPriceNonce.txInsert(item)
  xp.byNoncePrice.txInsert(item)
  xp.byGasTipCap.txInsert(item.tx.maxPriorityFee, item)
  xp.bySender.txInsert(item)
  ok()


proc reassign*(xp: var TxPoolBase; key: Hash256; local: bool): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Reassign transaction local/remote flag of a database entry. The function
  ## succeeds returning the wrapping transaction container if the transaction
  ## was found with a different local/remote flag than the argument `local`
  ## and subsequently was changed.
  let
    qSched = (not local).toQueueSched
    rc = xp.byIdQueue.eq(key, qSched)
  if rc.isOK:
    let item = rc.value
    if item.local != local:
      item.local = local
      # txAppend/txInsert will auto-delete an existing entry of the other queue
      xp.byIdQueue.txAppend(item)
      xp.bySender.txInsert(item)
      return true


proc delete*(xp: var TxPoolBase; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  if xp.byIdQueue.txDelete(item):
    xp.byPriceNonce.txDelete(item)
    xp.byNoncePrice.txDelete(item)
    xp.byGasTipCap.txDelete(item.tx.maxPriorityFee, item)
    xp.bySender.txDelete(item)
    return true

proc delete*(xp: var TxPoolBase; itemID: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Variant of `delete()`
  for localOK in [true, false]:
    let rc = xp.byIdQueue.eq(itemID, localOK.toQueueSched)
    if rc.isOK:
      if xp.delete(rc.value):
        return ok(rc.value)
  err()

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc nItems*(xp: var TxPoolBase): int {.inline.} =
  ## Total number of registered transactions
  xp.byIdQueue.nLeaves

proc nItems*(gasData: TxPriceNonceRef): int {.inline.} =
  ## Total number of registered transactions for sub-list
  gasData.nLeaves

proc nItems*(nonceData: TxNoncePriceRef): int {.inline.} =
  ## Total number of registered transactions for sub-list
  nonceData.nLeaves

proc nItems*(nonceData: TxPriceItemRef): int {.inline.} =
  ## Total number of registered transactions for sub-list, This function
  ## is syntactic sugar for `nonceData.itemList.len`
  nonceData.itemList.len

proc nItems*(nonceData: TxNonceItemRef): int {.inline.} =
  ## Ditto
  nonceData.itemList.len

proc byLocalQueueLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of transactions in local queue
  xp.byIdQueue.len(TxQueueLocal)

proc byRemoteQueueLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of transactions in local queue
  xp.byIdQueue.len(TxQueueRemote)


proc byPriceLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different `gasPrice` entries known.
  xp.byPriceNonce.len

proc byPriceLen*(nonceData: TxNoncePriceRef): int {.inline.} =
  ## Number of different `gasPrice` entries known for the sub-list argument
  ## `nonceData`. This number is positive.
  nonceData.len

proc byNonceLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different `gasPrice` entries known.
  xp.byNoncePrice.len

proc byNonceLen*(gasData: TxPriceNonceRef): int {.inline.} =
  ## Number of different `nonce` entries known for the sub-list argument
  ## `gasData`. This number is positive.
  gasData.len


proc byGasTipCapLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different `maxPriorityFee` entries known. For each gas price
  ## there is at least one transaction available.
  xp.byGasTipCap.len

proc bySenderLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different sendeer adresses known. For each address there is at
  ## least one transaction available.
  xp.bySender.len


proc gasPrice*(gasData: TxPriceNonceRef): GasInt =
  ## Returns the gas price associated with a `gasData` argument list (see
  ## comments on `byPriceNonceGe()` for details.)
  let nonceData = gasData.nonceList.ge(AccountNonce.low).value.data
  nonceData.itemList.firstKey.value.tx.gasPrice

proc gasPrice*(nonceData: TxPriceItemRef): GasInt {.inline.} =
  ## Ditto
  nonceData.itemList.firstKey.value.tx.gasPrice

proc nonce*(nonceData: TxNoncePriceRef): AccountNonce =
  ## Returns the nonce associated with a `nonceData` argument list (see
  ## comments on `byNoncePriceGe()` for details.)
  let gasData = nonceData.priceList.ge(GasInt.low).value.data
  gasData.itemList.firstKey.value.tx.nonce

proc nonce*(gasData: TxNonceItemRef): AccountNonce =
  ## Ditto
  gasData.itemList.firstKey.value.tx.nonce

# ------------------------------------------------------------------------------
# Public functions, ID queue query
# ------------------------------------------------------------------------------

proc hasItemID*(xp: var TxPoolBase; itemID: Hash256; local: bool): bool
    {.inline.} =
  ## Returns `true` if the argument pair `(key,local)` exists in the
  ## database.
  ##
  ## If this function returns `true`, then it is save to use the `xp[key]`
  ## paradigm for accessing a transaction container.
  xp.byIdQueue.hasItemID(itemID, local.toQueuesched)

proc toItemID*(tx: Transaction): Hash256 {.inline.} =
  ## Retrieves transaction key. Note that the returned argument will only apply
  ## to a transaction in the database if the argument transaction `tx` is
  ## exactly the same as the one passed earlier to the `insert()` function.
  tx.hash

proc hasTx*(xp: var TxPoolBase; tx: Transaction): bool {.inline.} =
  ## Returns `true` if the argument pair `(key,local)` exists in the
  ## database.
  ##
  ## If this function returns `true`, then it is save to use the `xp[key]`
  ## paradigm for accessing a transaction container.
  let itemID = tx.hash
  xp.hasItemID(itemID,true) or xp.hasItemID(itemID,false)


proc `[]`*(xp: var TxPoolBase; itemID: Hash256): TxItemRef
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
    let rc = xp.byIdQueue.eq(itemID, true.toQueuesched)
    if rc.isOK:
      return rc.value
  block:
    let rc = xp.byIdQueue.eq(itemID, false.toQueuesched)
    if rc.isOK:
      return rc.value


proc first*(xp: var TxPoolBase; local: bool): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  let rc =  xp.byIdQueue.first(local.toQueuesched)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc last*(xp: var TxPoolBase; local: bool): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.last(local.toQueuesched)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc next*(xp: var TxPoolBase;
           itemID: Hash256; local: bool): Result[TxItemRef,void]
    {.inline,inline,gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.next(local.toQueuesched, itemID)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc prev*(xp: var TxPoolBase;
           key: Hash256; local: bool): Result[TxItemRef,void]
    {.inline,inline,gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.prev(local.toQueuesched, key)
  if rc.isOK:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, sender query
# ------------------------------------------------------------------------------

proc bySenderEq*(xp: var TxPoolBase;
                 ethAddr: EthAddress): Result[TxGroupItemsRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the list of transaction records all with the same `ethAddr`
  ## argument sender address (if any.)
  if xp.bySender.hasKey(ethAddr):
    return ok(xp.bySender[ethAddr])
  err()

# ------------------------------------------------------------------------------
# Public functions, `gasPrice > nonce` item query
# ------------------------------------------------------------------------------

proc byPriceNonceGe*(xp: var TxPoolBase;
                   gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## First step in a cascaded `gasPrice > nonce` item lookup:
  ## ::
  ##   let rcGas = xq.byPriceNonceGe(gasPrice)
  ##   if rcGas.isOK:
  ##     let gasData = rcGas.value
  ##     let rcNonce = gasData.byNonceGe(AccountNonce.low)
  ##     if rcNonce.isOK:
  ##       let nonceData = rcNonce.value
  ##       let firstItem = nonceData.itemList.firstKey.value
  ##
  ## The example above retrieves the first item from the item list all with
  ## the same gas price which is the *least* price greater or equal the
  ## argument `gasPrice`.
  ##
  ## Note that in the example above, the statement *if rcNonce.isOK:* is
  ## always true (and redundant) because the sub-list is never empty.
  let rc = xp.byPriceNonce.ge(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceNonceGt*(xp: var TxPoolBase;
                   gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceNonceGe()`.
  let rc = xp.byPriceNonce.gt(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceNonceLe*(xp: var TxPoolBase;
                   gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceNonceGe()`.
  let rc = xp.byPriceNonce.le(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceNonceLt*(xp: var TxPoolBase;
                   gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceNonceGe()`.
  let rc = xp.byPriceNonce.lt(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceNonceEq*(xp: var TxPoolBase;
                   gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceNonceGe()`.
  let rc = xp.byPriceNonce.eq(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()


proc byNonceGe*(gasData: TxPriceNonceRef;
                nonce: AccountNonce): Result[TxPriceItemRef,void] =
  ## Secont step as explained in `byPriceNonceGe()`
  let rc = gasData.nonceList.ge(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNonceGt*(gasData: TxPriceNonceRef;
                nonce: AccountNonce): Result[TxPriceItemRef,void] =
  ## Similar to `byNonceGe()`
  let rc = gasData.nonceList.gt(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNonceLe*(gasData: TxPriceNonceRef;
                nonce: AccountNonce): Result[TxPriceItemRef,void] =
  ## Similar to `byNonceGe()`
  let rc = gasData.nonceList.le(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNonceLt*(gasData: TxPriceNonceRef;
                nonce: AccountNonce): Result[TxPriceItemRef,void] =
  ## Similar to `byNonceGe()`
  let rc = gasData.nonceList.lt(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNonceEq*(gasData: TxPriceNonceRef;
                nonce: AccountNonce): Result[TxPriceItemRef,void] =
  ## Similar to `byNonceGe()`
  let rc = gasData.nonceList.eq(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, `nonce > gasPrice` item query
# ------------------------------------------------------------------------------

proc byNoncePriceGe*(xp: var TxPoolBase;
                     nonce: AccountNonce): Result[TxNoncePriceRef,void] =
  ## First step in a cascaded `nonce > gasPrice` item lookup:
  ## ::
  ##   let rcNonce = xp.byNoncePriceGe(nonce)
  ##   if rcNonce.isOK:
  ##     let nonceData = rcNonce.value
  ##     let rcGas = nonceData.byPriceGe(AccountNonce.low)
  ##     if rcGas.isOK:
  ##       let gasData = rcGas.value
  ##       let firstItem = gasData.itemList.firstKey.value
  ##
  ## The example above retrieves the first item from the item list all with
  ## the same nonce which is the *least* nonce greater or equal the
  ## argument `nonce`.
  ##
  ## Note that in the example above, the statement *if rcGas.isOK:* is
  ## always true (and redundant) because the sub-list is never empty.
  let rc = xp.byNoncePrice.ge(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNoncePriceGt*(xp: var TxPoolBase;
                     nonce: AccountNonce): Result[TxNoncePriceRef,void] =
  ## Similar to `byNoncePriceGe()`.
  let rc = xp.byNoncePrice.gt(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNoncePriceLe*(xp: var TxPoolBase;
                     nonce: AccountNonce): Result[TxNoncePriceRef,void] =
  ## Similar to `byNoncePriceGe()`.
  let rc = xp.byNoncePrice.le(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNoncePriceLt*(xp: var TxPoolBase;
                     nonce: AccountNonce): Result[TxNoncePriceRef,void] =
  ## Similar to `byNoncePriceGe()`.
  let rc = xp.byNoncePrice.lt(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byNoncePriceEq*(xp: var TxPoolBase;
                     nonce: AccountNonce): Result[TxNoncePriceRef,void] =
  ## Similar to `byNoncePriceGe()`.
  let rc = xp.byNoncePrice.eq(nonce)
  if rc.isOk:
    return ok(rc.value.data)
  err()


proc byPriceGe*(nonceData: TxNoncePriceRef;
                gasPrice: GasInt): Result[TxNonceItemRef,void] =
  ## Secont step as explained in `byPriceNonceGe()`
  let rc = nonceData.priceList.ge(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceGt*(nonceData: TxNoncePriceRef;
                gasPrice: GasInt): Result[TxNonceItemRef,void] =
  ## Similar to `byPriceGe()`
  let rc = nonceData.priceList.gt(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceLe*(nonceData: TxNoncePriceRef;
                gasPrice: GasInt): Result[TxNonceItemRef,void] =
  ## Similar to `byPriceGe()`
  let rc = nonceData.priceList.le(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceLt*(nonceData: TxNoncePriceRef;
                gasPrice: GasInt): Result[TxNonceItemRef,void] =
  ## Similar to `byPriceGe()`
  let rc = nonceData.priceList.lt(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceEq*(nonceData: TxNoncePriceRef;
                gasPrice: GasInt): Result[TxNonceItemRef,void] =
  ## Similar to `byPriceGe()`
  let rc = nonceData.priceList.eq(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, `maxPriorityFee` item query
# ------------------------------------------------------------------------------

proc byGasTipCapGe*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItemsRef,void] =
  ## Retrieve the list of transaction records all with the same *least*
  ## `maxPriorityFee` item *greater or equal* the argument `gWei`. On success,
  ## the resulting list of transactions has at least one item.
  let rc = xp.byGasTipCap.ge(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasTipCapGt*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItemsRef,void] =
  ## Similar to `byGasTipCapGe()`.
  let rc = xp.byGasTipCap.gt(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasTipCapLe*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItemsRef,void] =
  ## Similar to `byGasTipCapGe()`.
  let rc = xp.byGasTipCap.le(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasTipCapLt*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItemsRef,void] =
  ## Similar to `byGasTipCapGe()`.
  let rc = xp.byGasTipCap.lt(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byGasTipCapEq*(xp: var TxPoolBase;
                   gWei: GasInt): Result[TxListItemsRef,void] =
  ## Similar to `byGasTipCapGe()`.
  let rc = xp.byGasTipCap.eq(gWei)
  if rc.isOk:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public functions, jobs queue mamgement
# ------------------------------------------------------------------------------

proc byJobsAdd*(xp: var TxPoolBase; data: TxJobData): TxJobID
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Appends a job to the *FIFO*. This function returns a non-zero *ID* if
  ## successful.
  ##
  ## :Note:
  ##   An error can only occur if
  ##   the *ID* of the first job follows the *ID* of the last job (*modulo*
  ##   `TxJobIdMax`.) This occurs when
  ##   * there are `TxJobIdMax` jobs already queued
  ##   * some jobs were deleted in the middle of the queue and the *ID*
  ##     gap was not shifted out yet.
  xp.byJobs.txAdd(data)

proc byJobsUnshift*(xp: var TxPoolBase; data: TxJobData): TxJobID
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Stores back a job to to the *FIFO* front end be re-fetched next. This
  ## function returns a non-zero *ID* if successful.
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  xp.byJobs.txUnshift(data)

proc byJobsDelete*(xp: var TxPoolBase; id: TxJobID): Result[TxJobPair,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete a job by argument `id`. The function returns the job just
  ## deleted (if successful.)
  ##
  ## See also the **Note* at the comment for `txAdd()`.
  xp.byJobs.txDelete(id)

proc byJobsShift*(xp: var TxPoolBase): Result[TxJobPair,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Fetches the next job from the *FIFO*. This is logically the same
  ## as `txFirst()` followed by `txDelete()`
  xp.byJobs.txShift

proc byJobsFirst*(xp: var TxPoolBase): Result[TxJobPair,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  xp.byJobs.txFirst

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator bySenderGroups*(xp: var TxPoolBase): TxGroupItemsRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over item lists grouped by sender addresses.
  var rc = xp.bySender.first
  while rc.isOK:
    let (key, itemList) = (rc.value.key, rc.value.data)
    rc = xp.bySender.next(key)
    yield itemList

# ------------

iterator byPriceNonceIncItem*(xp: var TxPoolBase;
                            minGasPrice = GasInt.low): TxPriceItemRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## gas prices followed by nonces.
  ##
  ## :Note:
  ##   When running in a loop it is ok to add or delete any entries,
  ##   vistied or not visited yet. So, deleting all entries with gas prices
  ##   less or equal than `delMin` would look like:
  ##   ::
  ##    for _, itList in xp.byPriceNonceIncItem(minGasPrice = delMin):
  ##      for item in itList.nextKeys:
  ##        discard xq.delete(item)
  var rcGas = xp.byPriceNonce.ge(minGasPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)

    var rcNonce = gasData.nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)

      yield nonceData
      rcNonce = gasData.nonceList.gt(nonceKey)
    rcGas = xp.byPriceNonce.gt(gaskey)

iterator byPriceNonceIncNonce*(xp: var TxPoolBase;
                             minGasPrice = GasInt.low): TxPriceNonceRef =
  ## Starting at the lowest gas price, this iterator traverses increasing
  ## gas prices. Contrary to `byPriceNonceIncItem()`, this iterator does not
  ## descent into the none sub-list and rather returns it.
  var rcGas = xp.byPriceNonce.ge(minGasPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    yield gasData
    rcGas = xp.byPriceNonce.gt(gaskey)

iterator byNonceInc*(gasData: TxPriceNonceRef;
                     minNonce = AccountNonce.low): TxPriceItemRef =
  ## Second part of a cascaded replacement for `byPriceNonceIncItem()`:
  ## ::
  ##   for gasData in xp.byPriceNonceIncNonce():
  ##     for nonceData in gasData.byNonceInc:
  ##       ...
  var rcNonce = gasData.nonceList.ge(minNonce)
  while rcNonce.isOk:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    yield nonceData
    rcNonce = gasData.nonceList.gt(nonceKey)


iterator byPriceNonceDecItem*(xp: var TxPoolBase;
                            maxGasPrice = GasInt.high): TxPriceItemRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceNonceIncPairs()`.
  var rcGas = xp.byPriceNonce.le(maxGasPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)

    var rcNonce = gasData.nonceList.le(AccountNonce.high)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)

      yield nonceData
      rcNonce = gasData.nonceList.lt(nonceKey)
    rcGas = xp.byPriceNonce.lt(gaskey)

iterator byPriceNonceDecNonce*(xp: var TxPoolBase;
                             maxGasPrice = GasInt.high): TxPriceNonceRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## gas prices. Contrary to `byPriceNonceDecItem()`, this iterator does not
  ## descent into the none sub-list and rather returns it.
  var rcGas = xp.byPriceNonce.le(maxGasPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    yield gasData
    rcGas = xp.byPriceNonce.lt(gaskey)

iterator byNonceDec*(gasData: TxPriceNonceRef;
                     maxNonce = AccountNonce.high): TxPriceItemRef =
  ## Second part of a cascaded replacement for `byPriceNonceDecItem()`:
  ## ::
  ##   for gasData in xp.byPriceNonceDecNonce():
  ##     for nonceData in gasData.byNonceDec:
  ##       ...
  var rcNonce = gasData.nonceList.le(maxNonce)
  while rcNonce.isOk:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    yield nonceData
    rcNonce = gasData.nonceList.lt(nonceKey)

# ------------

iterator byNoncePriceIncItem*(xp: var TxPoolBase;
                              minNonce = AccountNonce.low): TxNonceItemRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## nonces followed by gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceNonceIncPairs()`.
  var rcNonce = xp.byNoncePrice.ge(minNonce)
  if rcNonce.isOK:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)

    var rcGas = nonceData.priceList.ge(GasInt.low)
    if rcGas.isOK:
      let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)

      yield gasData
      rcGas = nonceData.priceList.gt(gasKey)
    rcNonce = xp.byNoncePrice.gt(nonceKey)

iterator byNoncePriceIncPrice*(xp: var TxPoolBase;
                               minNonce = AccountNonce.low): TxNoncePriceRef =
  ## Starting at the lowest nonce, this iterator traverses increasing nonces.
  ## Contrary to `byNonceNonceIncItem()`, this iterator does not descent into
  ## the none sub-list and rather returns it.
  var rcNonce = xp.byNoncePrice.ge(minNonce)
  if rcNonce.isOK:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    yield nonceData
    rcNonce = xp.byNoncePrice.gt(nonceKey)

iterator byPriceInc*(nonceData: TxNoncePriceRef;
                     minGasPrice = GasInt.low): TxNonceItemRef =
  ## Second part of a cascaded replacement for `byNoncePriceIncItem()`:
  ## ::
  ##   for nonceData in xp.byNoncePriceIncNonce():
  ##     for gasData in nonceData.byPriceInc:
  ##       ...
  var rcGas = nonceData.priceList.ge(minGasPrice)
  if rcGas.isOK:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    yield gasData
    rcGas = nonceData.priceList.gt(gasKey)


iterator byNoncePriceDecItem*(xp: var TxPoolBase;
                              maxNonce = AccountNonce.low): TxNonceItemRef =
  ## Starting at the lowest gas price, this function traverses decreasing
  ## nonces followed by gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceNonceIncPairs()`.
  var rcNonce = xp.byNoncePrice.le(maxNonce)
  if rcNonce.isOK:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)

    var rcGas = nonceData.priceList.le(GasInt.high)
    if rcGas.isOK:
      let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)

      yield gasData
      rcGas = nonceData.priceList.gt(gasKey)
    rcNonce = xp.byNoncePrice.gt(nonceKey)

iterator byNoncePriceDecPrice*(xp: var TxPoolBase;
                               maxNonce = AccountNonce.low): TxNoncePriceRef =
  ## Starting at the lowest nonce, this iterator traverses decreasing nonces.
  ## Contrary to `byNonceNonceIncItem()`, this iterator does not descent into
  ## the none sub-list and rather returns it.
  var rcNonce = xp.byNoncePrice.le(maxNonce)
  if rcNonce.isOK:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    yield nonceData
    rcNonce = xp.byNoncePrice.lt(nonceKey)

iterator byPriceDec*(nonceData: TxNoncePriceRef;
                     maxGasPrice = GasInt.low): TxNonceItemRef =
  ## Second part of a cascaded replacement for `byNoncePriceIncItem()`:
  ## ::
  ##   for nonceData in xp.byNoncePriceIncNonce():
  ##     for gasData in nonceData.byPriceInc:
  ##       ...
  var rcGas = nonceData.priceList.le(maxGasPrice)
  if rcGas.isOK:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    yield gasData
    rcGas = nonceData.priceList.lt(gasKey)

# ------------

iterator byGasTipCapInc*(xp: var TxPoolBase;
                         fromGe = GasInt.low): TxListItemsRef =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceNonceIncPairs()`.
  var rc = xp.byGasTipCap.ge(fromGe)
  while rc.isOk:
    let yKey = rc.value.key
    yield rc.value.data
    rc = xp.byGasTipCap.gt(ykey)

iterator byGasTipCapDec*(xp: var TxPoolBase;
                         fromLe = GasInt.high): TxListItemsRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceNonceIncPairs()`.
  var rc = xp.byGasTipCap.le(fromLe)
  while rc.isOk:
    let yKey = rc.value.key
    yield rc.value.data
    rc = xp.byGasTipCap.lt(yKey)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: var TxPoolBase): Result[void,TxBaseInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.byPriceNonce.txVerify
    if rc.isErr:
      case rc.error[0]
      of txPriceOk:           return err(txOk)
      of txPriceVfyRbTree:    return err(txVfyByPriceList)
      of txPriceVfyLeafEmpty: return err(txVfyByPriceLeafEmpty)
      of txPriceVfyLeafQueue: return err(txVfyByPriceLeafQueue)
      of txPriceVfySize:      return err(txVfyByPriceTotal)
  block:
    let rc = xp.byNoncePrice.txVerify
    if rc.isErr:
      case rc.error[0]
      of txNonceOk:           return err(txOk)
      of txNonceVfyRbTree:    return err(txVfyByNonceList)
      of txNonceVfyLeafEmpty: return err(txVfyByNonceLeafEmpty)
      of txNonceVfyLeafQueue: return err(txVfyByNonceLeafQueue)
      of txNonceVfySize:      return err(txVfyByNonceTotal)
  block:
    let rc = xp.byGasTipCap.txVerify
    if rc.isErr:
      case rc.error[0]
      of txListOk:            return err(txOk)
      of txListVfyRbTree:     return err(txVfyByGasTipCapList)
      of txListVfyLeafEmpty:  return err(txVfyByGasTipCapLeafEmpty)
      of txListVfyLeafQueue:  return err(txVfyByGasTipCapLeafQueue)
      of txListVfySize:       return err(txVfyByGasTipCapTotal)
  block:
    let rc = xp.bySender.txVerify
    if rc.isErr:
      case rc.error[0]
      of txGroupOk:           return err(txOk)
      of txGroupVfyQueue:     return err(txVfyBySenderQueue)
      of txGroupVfyLeafEmpty: return err(txVfyBySenderLeafEmpty)
      of txGroupVfyLeafQueue: return err(txVfyBySenderLeafQueue)
      of txGroupVfySize:      return err(txVfyBySenderTotal)
  block:
    let rc = xp.byIdQueue.txVerify
    if rc.isErr:
      case rc.error[0]
      of txQuOk:              return err(txOk)
      of txQuVfyQueueList:    return err(txVfyByIdQueueList)
      of txQuVfyQueueKey:     return err(txVfyByIdQueueKey)
      of txQuVfySchedule:     return err(txVfyByIdQueueSchedule)
  block:
    let rc = xp.byJobs.txVerify
    if rc.isErr:
      case rc.error[0]
      of txJobsOk:            return err(txOk)
      of txJobsVfyQueue:      return err(txVfyByJobsQueue)

  if xp.byIdQueue.nLeaves != xp.bySender.nLeaves:
     return err(txVfyBySenderTotal)

  if xp.byIdQueue.nLeaves != xp.byPriceNonce.nLeaves:
     return err(txVfyByPriceTotal)

  if xp.byIdQueue.nLeaves != xp.byNoncePrice.nLeaves:
     return err(txVfyByNonceTotal)

  if xp.byIdQueue.nLeaves != xp.byGasTipCap.nLeaves:
     return err(txVfyByGasTipCapTotal)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
