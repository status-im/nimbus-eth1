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
  ../../db/accounts_cache,
  ../../forks,
  ../../transaction,
  ../keequ,
  ../slst,
  ./tx_dbhead,
  ./tx_desc,
  ./tx_gauge,
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  ./tx_tabs/[tx_itemid, tx_leaf, tx_sender, tx_status],
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
# Private validation helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(xp: var TxPool; item: TxItemRef): bool =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Rejected transactions will go to the wastebasket
  ##
  if item.tx.txType == TxEip2930 and xp.dbHead.fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if item.tx.txType == TxEip1559 and xp.dbHead.fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  let nonce = ReadOnlyStateDB(xp.dbHead.accDb).getNonce(item.sender)
  if item.tx.nonce < nonce:
    debug "invalid tx: account nonce mismatch",
      txNonce = item.tx.nonce,
      accountNonce = nonce
    return false

  if item.tx.gasLimit < item.tx.intrinsicGas(xp.dbHead.fork):
    debug "invalid tx: not enough gas to perform calculation",
      available = item.tx.gasLimit,
      require = item.tx.intrinsicGas(xp.dbHead.fork)
    return false

  true

proc checkTxFees(xp: var TxPool; item: TxItemRef): bool =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Rejected transactions will go to the queue(1) waiting for a change
  ## of parameters `gasLimit` and `baseFee`
  ##
  if xp.dbHead.trgGasLimit < item.tx.gasLimit:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = xp.dbHead.trgGasLimit,
      gasLimit = item.tx.gasLimit
    return false

  # ensure that the user was willing to at least pay the base fee
  if item.tx.txType == TxLegacy:
    if item.tx.gasPrice < xp.dbHead.baseFee.int64:
      debug "invalid tx: legacy gasPrice is smaller than baseFee",
        gasPrice = item.tx.gasPrice,
        baseFee = xp.dbHead.baseFee
      return false
  else:
    if item.tx.maxFee < xp.dbHead.baseFee.int64:
      debug "invalid tx: maxFee is smaller than baseFee",
        maxFee = item.tx.maxFee,
        baseFee = baseFee
      return false
    # The total must be the larger of the two
    if item.tx.maxFee < item.tx.maxPriorityFee:
      debug "invalid tx: maxFee is smaller than maPriorityFee",
        maxFee = item.tx.maxFee,
        maxPriorityFee = item.tx.maxPriorityFee
      return false

  true

proc checkTxBalance(xp: var TxPool; item: TxItemRef): bool =
  ## Inspired by `p2p/validate.validateTransaction()`
  ##
  ## Function currently unused.
  ##
  let
    balance = ReadOnlyStateDB(xp.dbHead.accDb).getBalance(item.sender)
    gasCost = item.tx.gasLimit.u256 * item.tx.gasPrice.u256
  if balance < gasCost:
    debug "invalid tx: not enough cash for gas",
      available = balance,
      require = gasCost
    return false

  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < item.tx.value:
    debug "invalid tx: not enough cash to send",
      available = balance,
      availableMinusGas = balanceOffGasCost,
      require = item.tx.value
    return false

  true

# ------------------------------------------------------------------------------
# Private validation functions
# ------------------------------------------------------------------------------

proc acceptTxValid(xp: var TxPool; item: TxItemRef): TxInfo =
  ## Check a raw transaction
  if not xp.checkTxBasic(item):
    return txInfoErrBasicValidatorFailed

  txInfoOk


proc acceptTxPending(xp: var TxPool; item: TxItemRef): bool =
  ## Check whether a valid transaction is ready to be set `pending`
  if item.tx.estimatedGasTip(xp.dbHead.baseFee) <= 0:
    return false

  if not xp.checkTxFees(item):
    return false

  #if not item.checkTxBalance(dbHead):
  #  return false

  true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(384): for addr := range pool.queue {
proc deleteExpiredItems*(xp: var TxPool; maxLifeTime: Duration)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Any non-local transaction old enough will be removed
  let deadLine = utcNow() - maxLifeTime
  var rc = xp.txDB.byItemID.eq(local = false).first
  while rc.isOK:
    let item = rc.value.data
    if deadLine < item.timeStamp:
      break
    rc = xp.txDB.byItemID.eq(local = false).next(item.itemID)
    discard xp.txDB.reject(item,txInfoErrTxExpired)
    queuedEvictionMeter(1)


# core/tx_pool.go(444): func (pool *TxPool) SetGasPrice(price *big.Int) {
proc deleteUnderpricedItems*(xp: var TxPool; price: uint64)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Drop all transactions below the argument threshold `price`, i.e.
  ## move these items to the waste basket.
  # Delete while walking the `gasFeeCap` table (it is ok to delete the
  # current item). See also `remotesBelowTip()`.
  if 0 < price:
    let topOffOne = price - 1
    for itemList in xp.txDB.byTipCap.decItemList(maxCap = topOffOne):
      for item in itemList.walkItems:
        if not item.local:
          discard xp.txDB.reject(item,txInfoErrUnderpriced)


# core/tx_pool.go(889): func (pool *TxPool) addTxs(txs []*types.Transaction, ..
proc addTxs*(xp: var TxPool;
             txs: var openArray[Transaction]; local: bool;  info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Queue a batch of transactions. There transactions are quickly tested
  ## and moved to the waiting queue, or into the waste basket.
  for tx in txs.mitems:
    var
      status = txItemQueued
      vetted = txInfoOk

    # Leave this frame with `continue`, or proceeed with error
    block txErrorFrame:
      var
        itemID = tx.itemID
        item: TxItemRef

      # Create tx ID and check for dups
      if xp.txDB.byItemID.hasKey(itemID):
        vetted = txInfoErrAlreadyKnown
        break txErrorFrame

      # Create tx wrapper with meta data (status may be changed, later)
      block:
        let rc = tx.newTxItemRef(itemID, local, status, info)
        if rc.isErr:
          vetted = txInfoErrInvalidSender
          break txErrorFrame
        item = rc.value

      # Verify transaction
      vetted = xp.acceptTxValid(item)
      if vetted != txInfoOk:
        break txErrorFrame

      # Update initial state
      if xp.acceptTxPending(item):
        status = txItemPending
        item.status = status

      # Insert into database
      let rc = xp.txDB.insert(item)
      if rc.isErr:
        vetted = rc.error
        break txErrorFrame

      # All done, this time
      validTxMeter(1)
      continue

      # Error processing below

    # store tx in waste basket
    xp.txDB.reject(tx, vetted, local, status, info)

    # update gauge
    case vetted:
    of txInfoErrAlreadyKnown:
      knownTxMeter(1)
    of txInfoErrInvalidSender:
      invalidTxMeter(1)
    else:
      unspecifiedErrorMeter(1)


# core/tx_pool.go(561): func (pool *TxPool) Locals() []common.Address {
proc collectAccounts*(xp: var TxPool; local: bool): seq[EthAddress]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Retrieves the accounts currently considered local by the pool.
  var rc = xp.txDB.bySender.first
  while rc.isOK:
    let (addrKey, schedList) = (rc.value.key, rc.value.data)
    rc = xp.txDB.bySender.next(addrKey)
    if 0 < schedList.eq(local).nItems:
      result.add addrKey


# core/tx_pool.go(1797): func (t *txLookup) RemoteToLocals(locals ..
proc reassignRemoteToLocals*(xp: var TxPool; signer: EthAddress): int
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## For given account, remote transactions are migrated to local transactions.
  ## The function returns the number of transactions migrated.
  let rc = xp.txDB.bySender.eq(signer).eq(local = false)
  if rc.isOK:
    let nRemotes = xp.txDB.byItemID.eq(local = false).nItems
    for itemList in rc.value.data.walkItemList:
      for item in itemList.walkItems:
        discard xp.txDB.reassign(item, local = true)
    return nRemotes - xp.txDB.byItemID.eq(local = false).nItems


# core/tx_pool.go(1813): func (t *txLookup) RemotesBelowTip(threshold ..
proc getRemotesBelowTip*(xp: var TxPool; threshold: uint64): seq[Hash256]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Finds all remote transactions below the given tip threshold.
  if 0 < threshold:
    for itemList in xp.txDB.byTipCap.decItemList(maxCap = threshold - 1):
      for item in itemList.walkItems:
        if not item.local:
          result.add item.itemID


proc updateGasPrice*(xp: var TxPool; curPrice: var uint64; newPrice: uint64)
    {.inline, raises: [Defect,KeyError].} =
  let oldPrice = curPrice
  curPrice = newPrice

  # if min miner fee increased, remove txs below the new threshold
  if oldPrice < newPrice:
    xp.deleteUnderpricedItems(newPrice)

  info "Price threshold updated",
    oldPrice,
    newPrice

proc updatePending*(xp: var TxPool; dbHead: var TxDbHead)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Similar to `addTxs()` only for queued or pending items on the system.
  var
    stashed: seq[TxItemRef]
    stashStatus = txItemQueued
    updateStatus = txItemPending

  # prepare: stash smaller sub-list, update larger one
  let
    nPending = xp.txDB.byStatus.eq(txItemPending).nItems
    nQueued = xp.txDB.byStatus.eq(txItemQueued).nItems
  if nPending < nQueued:
    stashStatus = txItemPending
    updateStatus = txItemQueued

  # action, first step: stash smaller sub-list
  for itemList in xp.txDB.byStatus.incItemList(stashStatus):
    for item in itemList.walkItems:
      stashed.add item

  # action, second step: update larger sub-list
  for itemList in xp.txDB.byStatus.incItemList(updateStatus):
    for item in itemList.walkItems:
      let newStatus =
        if xp.acceptTxPending(item): txItemPending
        else: txItemQueued
      if newStatus != updateStatus:
        discard xp.txDB.reassign(item, newStatus)

  # action, finalise: update smaller, stashed sup-list
  for item in stashed:
    let newStatus =
      if xp.acceptTxPending(item): txItemPending
      else: txItemQueued
    if newStatus != stashStatus:
      discard xp.txDB.reassign(item, newStatus)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
