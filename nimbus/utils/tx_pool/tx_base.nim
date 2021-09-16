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
  ./tx_gas,
  ./tx_item,
  ./tx_price,
  ./tx_queue,
  ./tx_sender,
  eth/[common, keys],
  stew/results

type
  TxBaseInfo* = enum ##\
    ## Error codes (as used in verification function.)
    txOk = 0

    txBaseErrAlreadyKnown
    txBaseErrInvalidSender

    # failed verifier codes
    txVfyByIdQueueList        ## Corrupted ID queue/fifo structure
    txVfyByIdQueueKey         ## Corrupted ID queue/fifo container id
    txVfyByIdQueueSchedule    ## Local flag indicates wrong schedule

    txVfyBySenderRbTree       ## Corrupted sender list structure
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

    txVfyByTipCapList         ## Corrupted gas price list structure
    txVfyByTipCapLeafEmpty    ## Empty gas price list leaf record
    txVfyByTipCapLeafQueue    ## Corrupted gas price leaf queue
    txVfyByTipCapTotal        ## Wrong number of leaves

    # codes provided for other modules
    txVfyByJobsQueue          ## Corrupted jobs queue/fifo structure


  TxPoolBase* = object of RootObj ##\
    ## Base descriptor
    baseFee: GasInt           ## `byPrice` re-org when changing
    byIdQueue: TxQueue        ## Primary table, queued by arrival event
    byPrice: TxPriceTab       ## Indexed by `effectiveGasTip` > `nonce`
    byTipCap: TxGasTab        ## Indexed by `gasTipCap`
    bySender: TxSenderTab     ## Indexed by `sender` > `local`

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# core/types/transaction.go(346): .. EffectiveGasTipValue(baseFee ..
proc updateEffectiveGasTip(xp: var TxPoolBase): TxPriceItemMap =
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

method init*(xp: var TxPoolBase; baseFee = GasInt.low) {.base.} =
  ## Constructor, returns new tx-pool descriptor.
  xp.baseFee = baseFee
  xp.byIdQueue.txInit
  xp.byPrice.txInit(update = xp.updateEffectiveGasTip)
  xp.byTipCap.txInit
  xp.bySender.txInit

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
  let itemID = tx.itemID
  if xp.byIdQueue.hasItemID(itemID):
    return err(txBaseErrAlreadyKnown)
  let rc = tx.newTxItemRef(itemID, local, info)
  if rc.isErr:
    return err(txBaseErrInvalidSender)
  let item = rc.value
  xp.byIdQueue.txAppend(item)
  xp.byPrice.txInsert(item)
  xp.byTipCap.txInsert(item.tx.gasTipCap, item)
  xp.bySender.txInsert(item)
  ok()


proc reassign*(xp: var TxPoolBase; item: TxItemRef; local: bool): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Reassign transaction local/remote flag of a database entry. The function
  ## succeeds returning the wrapping transaction container if the transaction
  ## was found with a different local/remote flag than the argument `local`
  ## and subsequently was changed.
  if item.local != local:
    # make sure that the argument `item` is not some copy
    let rc = xp.byIdQueue.eq(item.itemID, item.local.toQueueSched)
    if rc.isOK:
      var realItem = rc.value
      xp.bySender.txDelete(realItem)  # delete original
      realItem.local = local
      xp.bySender.txInsert(realItem)  # re-insert changed
      xp.byIdQueue.txAppend(realItem) # implicit re-assign
      return true


proc delete*(xp: var TxPoolBase; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  if xp.byIdQueue.txDelete(item):
    xp.byPrice.txDelete(item)
    xp.byTipCap.txDelete(item.tx.gasTipCap, item)
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
# Public getters: descriptor related
# ------------------------------------------------------------------------------

proc baseFee*(xp: var TxPoolBase): GasInt {.inline.} =
  ## Get the `baseFee` implying the price list valuation and order. If
  ## this entry is disabled, the value `GasInt.low` is returnded.
  xp.baseFee


proc nItems*(xp: var TxPoolBase): int {.inline.} =
  ## Total number of registered transactions
  xp.byIdQueue.nLeaves

proc nItems*(gasData: TxPriceNonceRef): int {.inline.} =
  ## Total number of registered transactions for sub-list
  gasData.nLeaves

proc nItems*(nonceData: TxPriceItemRef): int {.inline.} =
  ## Total number of registered transactions for sub-list, This function
  ## is syntactic sugar for `nonceData.itemList.len`
  nonceData.itemList.len

proc nItems*(addrData: TxSenderSchedRef): int {.inline.} =
  ## Ditto
  addrData.nLeaves

proc nItems*(schedData: TxSenderNonceRef): int {.inline.} =
  ## Ditto
  schedData.nLeaves


proc byLocalQueueLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of transactions in local queue
  xp.byIdQueue.len(TxQueueLocal)

proc byRemoteQueueLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of transactions in local queue
  xp.byIdQueue.len(TxQueueRemote)

# ------------------------------------------------------------------------------
# Public getters: transaction related
# ------------------------------------------------------------------------------

proc gasTipCap*(gasData: TxGasItemRef): GasInt {.inline.} =
  ## Returns the `gasTipCap` of the transaction,
  gasData.itemList.firstKey.value.tx.gasTipCap


proc sender*(schedData: TxSenderNonceRef): EthAddress =
  ## Returns the sender address.
  let nonceData = schedData.nonceList.ge(AccountNonce.low).value.data
  nonceData.itemList.firstKey.value.sender

proc sender*(addrData: TxSenderSchedRef): EthAddress =
  ## Returns the sender address.
  var rc = addrData.eq(true)
  if rc.isErr:
    rc = addrData.eq(false)
  rc.value.sender


proc effectiveGasTip*(gasData: TxPriceNonceRef): GasInt =
  ## Returns the price associated with a `effectiveGasTip` argument list.
  ## Note that this is a virtual getter depending on the `baseFee` of
  ## the underlying sorted tist.
  let nonceData = gasData.nonceList.ge(AccountNonce.low).value.data
  nonceData.itemList.firstKey.value.effectiveGasTip

proc effectiveGasTip*(nonceData: TxPriceItemRef): GasInt {.inline.} =
  ## Ditto
  nonceData.itemList.firstKey.value.effectiveGasTip


proc nonce*(nonceData: TxPriceItemRef): AccountNonce {.inline.} =
  ## Returns the nonce associated with a `nonceData` argument list.
  nonceData.itemList.firstKey.value.tx.nonce

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(xp: var TxPoolBase; baseFee: GasInt)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Setter, new base fee (implies reorg). The argument `GasInt.low`
  ## disables the `baseFee`.
  xp.baseFee = baseFee
  xp.byPrice.update = xp.updateEffectiveGasTip

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
  tx.itemID

proc hasTx*(xp: var TxPoolBase; tx: Transaction): bool {.inline.} =
  ## Returns `true` if the argument pair `(key,local)` exists in the
  ## database.
  ##
  ## If this function returns `true`, then it is save to use the `xp[key]`
  ## paradigm for accessing a transaction container.
  let itemID = tx.itemID
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
# Public functions, `sender > local > nonce` query
# ------------------------------------------------------------------------------

proc bySenderLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different sendeer adresses known. For each address there is at
  ## least one transaction available.
  xp.bySender.len

proc bySenderEq*(xp: var TxPoolBase;
                 sender: EthAddress): Result[TxSenderSchedRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the sub-list of transaction records all with the same `sender`
  ## argument sender address (if any.)
  xp.bySender.eq(sender)

proc bySenderEq*(xp: var TxPoolBase;
                 sender: EthAddress; local: bool): Result[TxSenderNonceRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieve the sub-list of transaction records all with the same `sender`
  ## argument sender address (if any.)
  xp.bySender.eq(sender,local)

# ------------------------------------------------------------------------------
# Public functions, `gasPrice > nonce` item query
# ------------------------------------------------------------------------------

proc byPriceLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different `gasPrice` entries known.
  xp.byPrice.len

proc byPriceGe*(xp: var TxPoolBase;
                gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## First step in a cascaded `gasPrice > nonce` item lookup:
  ## ::
  ##   let rcGas = xq.byPriceGe(gasPrice)
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
  let rc = xp.byPrice.ge(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceGt*(xp: var TxPoolBase;
                gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceGe()`.
  let rc = xp.byPrice.gt(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceLe*(xp: var TxPoolBase;
                gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceGe()`.
  let rc = xp.byPrice.le(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceLt*(xp: var TxPoolBase;
                gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceGe()`.
  let rc = xp.byPrice.lt(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

proc byPriceEq*(xp: var TxPoolBase;
                gasPrice: GasInt): Result[TxPriceNonceRef,void] =
  ## Similar to `byPriceGe()`.
  let rc = xp.byPrice.eq(gasPrice)
  if rc.isOk:
    return ok(rc.value.data)
  err()

# ------

proc byNonceLen*(gasData: TxPriceNonceRef): int {.inline.} =
  ## Number of different `nonce` entries known for the sub-list argument
  ## `gasData`. This number is positive.
  gasData.len

proc byNonceGe*(gasData: TxPriceNonceRef;
                nonce: AccountNonce): Result[TxPriceItemRef,void] =
  ## Secont step as explained in `byPriceGe()`
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
# Public functions, `gasTipCap` item query
# ------------------------------------------------------------------------------

proc byTipCapLen*(xp: var TxPoolBase): int {.inline.} =
  ## Number of different `gasTipCap` entries known. For each gas price
  ## there is at least one transaction available.
  xp.byTipCap.len

proc byTipCapGe*(xp: var TxPoolBase; gas: GasInt): Result[TxGasItemRef,void] =
  ## Retrieve the list of transaction records all with the same *least*
  ## `gasTipCap` item *greater or equal* the argument `gas`. On success,
  ## the resulting list of transactions has at least one item.
  let rc = xp.byTipCap.ge(gas)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc byTipCapGt*(xp: var TxPoolBase; gas: GasInt): Result[TxGasItemRef,void] =
  ## Similar to `byTipCapGe()`.
  let rc = xp.byTipCap.gt(gas)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc byTipCapLe*(xp: var TxPoolBase; gas: GasInt): Result[TxGasItemRef,void] =
  ## Similar to `byTipCapGe()`.
  let rc = xp.byTipCap.le(gas)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc byTipCapLt*(xp: var TxPoolBase; gas: GasInt): Result[TxGasItemRef,void] =
  ## Similar to `byTipCapGe()`.
  let rc = xp.byTipCap.lt(gas)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc byTipCapEq*(xp: var TxPoolBase; gas: GasInt): Result[TxGasItemRef,void] =
  ## Similar to `byTipCapGe()`.
  let rc = xp.byTipCap.eq(gas)
  if rc.isOK:
    return ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator bySenderItem*(xp: var TxPoolBase): TxSenderItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over item lists grouped by sender addresses.
  var rcAddr = xp.bySender.first
  while rcAddr.isOK:
    let (addrKey, addrData) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = xp.bySender.next(addrKey)

    for local in [true, false]:
      let rcSched = addrData.eq(local)

      if rcSched.isOk:
        let schedData = rcSched.value

        var rcNonce = schedData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = schedData.nonceList.gt(nonceKey)

          yield nonceData

iterator bySenderSched*(xp: var TxPoolBase): TxSenderSchedRef =
  ## Walk over item lists grouped by sender addresses and local/remote. This
  ## iterator stops at the `TxSenderSchedRef` level sub-list.
  var rcAddr = xp.bySender.first
  while rcAddr.isOK:
    let (addrKey, addrData) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = xp.bySender.next(addrKey)

    yield addrData

iterator bySenderNonce*(xp: var TxPoolBase;
                        local: varArgs[bool]): TxSenderNonceRef =
  ## Walk over item lists grouped by sender addresses and local/remote. This
  ## iterator stops at the `TxSenderNonceRef` level sub-list.
  var rcAddr = xp.bySender.first
  while rcAddr.isOK:
    let (addrKey, addrData) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = xp.bySender.next(addrKey)

    for isLocal in local:
      let rcSched = addrData.eq(isLocal)
      if rcSched.isOk:
        yield rcSched.value

iterator byNonceItem*(schedData: TxSenderNonceRef): TxSenderItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Top level part to replace `xp.bySenderItem` with:
  ## ::
  ##  for schedData in xp.bySenderNonce(true,false):
  ##    for nonceData in schedData.byNonceItem:
  ##      ...
  ##
  var rcNonce = schedData.nonceList.ge(AccountNonce.low)
  while rcNonce.isOk:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    rcNonce = schedData.nonceList.gt(nonceKey)

    yield nonceData

# ------------

iterator byPriceIncItem*(xp: var TxPoolBase;
                         minPrice = GasInt.low): TxPriceItemRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## gas prices followed by nonces.
  ##
  ## :Note:
  ##   When running in a loop it is ok to add or delete any entries,
  ##   vistied or not visited yet. So, deleting all entries with gas prices
  ##   less or equal than `delMin` would look like:
  ##   ::
  ##    for data in xp.byPriceIncItem(minPrice = delMin):
  ##      for item in data.nextKeys:
  ##        discard xq.delete(item)
  var rcGas = xp.byPrice.ge(minPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)

    var rcNonce = gasData.nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)

      yield nonceData
      rcNonce = gasData.nonceList.gt(nonceKey)
    rcGas = xp.byPrice.gt(gaskey)

iterator byPriceIncNonce*(xp: var TxPoolBase;
                          minPrice = GasInt.low): TxPriceNonceRef =
  ## Starting at the lowest gas price, this iterator traverses increasing
  ## gas prices. Contrary to `byPriceIncItem()`, this iterator does not
  ## descent into the none sub-list and rather returns it.
  var rcGas = xp.byPrice.ge(minPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    yield gasData
    rcGas = xp.byPrice.gt(gaskey)

iterator byNonceInc*(gasData: TxPriceNonceRef;
                     minNonce = AccountNonce.low): TxPriceItemRef =
  ## Second part of a cascaded replacement for `byPriceIncItem()`:
  ## ::
  ##   for gasData in xp.byPriceIncNonce:
  ##     for nonceData in gasData.byNonceInc:
  ##       ...
  var rcNonce = gasData.nonceList.ge(minNonce)
  while rcNonce.isOk:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    yield nonceData
    rcNonce = gasData.nonceList.gt(nonceKey)


iterator byPriceDecItem*(xp: var TxPoolBase;
                         maxPrice = GasInt.high): TxPriceItemRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceIncPairs()`.
  var rcGas = xp.byPrice.le(maxPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)

    var rcNonce = gasData.nonceList.le(AccountNonce.high)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)

      yield nonceData
      rcNonce = gasData.nonceList.lt(nonceKey)
    rcGas = xp.byPrice.lt(gaskey)

iterator byPriceDecNonce*(xp: var TxPoolBase;
                          maxPrice = GasInt.high): TxPriceNonceRef =
  ## Starting at the lowest gas price, this function traverses increasing
  ## gas prices. Contrary to `byPriceDecItem()`, this iterator does not
  ## descent into the none sub-list and rather returns it.
  var rcGas = xp.byPrice.le(maxPrice)
  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    yield gasData
    rcGas = xp.byPrice.lt(gaskey)

iterator byNonceDec*(gasData: TxPriceNonceRef;
                     maxNonce = AccountNonce.high): TxPriceItemRef =
  ## Second part of a cascaded replacement for `byPriceDecItem()`:
  ## ::
  ##   for gasData in xp.byPriceDecNonce():
  ##     for nonceData in gasData.byNonceDec:
  ##       ...
  var rcNonce = gasData.nonceList.le(maxNonce)
  while rcNonce.isOk:
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    yield nonceData
    rcNonce = gasData.nonceList.lt(nonceKey)

# ------------

iterator byTipCapInc*(xp: var TxPoolBase; minCap = GasInt.low): TxGasItemRef =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceIncPairs()`.
  var rc = xp.byTipCap.ge(minCap)
  while rc.isOk:
    let yKey = rc.value.key
    yield rc.value.data
    rc = xp.byTipCap.gt(ykey)

iterator byTipCapDec*(xp: var TxPoolBase; maxCap = GasInt.high): TxGasItemRef =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## See also the **Note* at the comment for `byPriceIncPairs()`.
  var rc = xp.byTipCap.le(maxCap)
  while rc.isOk:
    let yKey = rc.value.key
    yield rc.value.data
    rc = xp.byTipCap.lt(yKey)

# ------------------------------------------------------------------------------
# Public functions, debugging
# ------------------------------------------------------------------------------

proc verify*(xp: var TxPoolBase): Result[void,TxBaseInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.byPrice.txVerify
    if rc.isErr:
      case rc.error[0]
      of txPriceOk:           return err(txOk)
      of txPriceVfyRbTree:    return err(txVfyByPriceList)
      of txPriceVfyLeafEmpty: return err(txVfyByPriceLeafEmpty)
      of txPriceVfyLeafQueue: return err(txVfyByPriceLeafQueue)
      of txPriceVfySize:      return err(txVfyByPriceTotal)
  block:
    let rc = xp.byTipCap.txVerify
    if rc.isErr:
      case rc.error[0]
      of txGasOk:             return err(txOk)
      of txGasVfyRbTree:      return err(txVfyByTipCapList)
      of txGasVfyLeafEmpty:   return err(txVfyByTipCapLeafEmpty)
      of txGasVfyLeafQueue:   return err(txVfyByTipCapLeafQueue)
      of txGasVfySize:        return err(txVfyByTipCapTotal)
  block:
    let rc = xp.bySender.txVerify
    if rc.isErr:
      case rc.error[0]
      of txSenderOk:           return err(txOk)
      of txSenderVfyRbTree:    return err(txVfyBySenderRbTree)
      of txSenderVfyLeafEmpty: return err(txVfyBySenderLeafEmpty)
      of txSenderVfyLeafQueue: return err(txVfyBySenderLeafQueue)
      of txSenderVfySize:      return err(txVfyBySenderTotal)
  block:
    let rc = xp.byIdQueue.txVerify
    if rc.isErr:
      case rc.error[0]
      of txQuOk:              return err(txOk)
      of txQuVfyQueueList:    return err(txVfyByIdQueueList)
      of txQuVfyQueueKey:     return err(txVfyByIdQueueKey)
      of txQuVfySchedule:     return err(txVfyByIdQueueSchedule)

  if xp.byIdQueue.nLeaves != xp.bySender.nLeaves:
     return err(txVfyBySenderTotal)

  if xp.byIdQueue.nLeaves != xp.byPrice.nLeaves:
     return err(txVfyByPriceTotal)

  if xp.byIdQueue.nLeaves != xp.byTipCap.nLeaves:
     return err(txVfyByTipCapTotal)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
