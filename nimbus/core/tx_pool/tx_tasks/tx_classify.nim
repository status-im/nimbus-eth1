# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Classify Transactions
## ===============================================
##

import
  ../../../common/common,
  ../../../vm_state,
  ../../../vm_types,
  ../../validate,
  ../../eip4844,
  ../tx_chain,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/keys

import ../../../transaction except GasPrice, GasPriceEx  # already in tx_item

{.push raises: [].}

logScope:
  topics = "tx-pool classify"

# ------------------------------------------------------------------------------
# Private function: tx validity check helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(xp: TxPoolRef; item: TxItemRef): bool =
  let res = validateTxBasic(
    item.tx,
    xp.chain.nextFork,
    # A new transaction of the next fork may be
    # coming before the fork activated
    validateFork = false
  )
  if res.isOk:
    return true
  item.info = res.error
  return false

proc checkTxNonce(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [CatchableError].} =
  ## Make sure that there is only one contiuous sequence of nonces (per
  ## sender) starting at the account nonce.

  # get the next applicable nonce as registered on the account database
  let accountNonce = xp.chain.getNonce(item.sender)

  if item.tx.payload.nonce < accountNonce:
    debug "invalid tx: account nonce too small",
      txNonce = item.tx.payload.nonce,
      accountNonce
    return false

  elif accountNonce < item.tx.payload.nonce:
    # for an existing account, nonces must come in increasing consecutive order
    let rc = xp.txDB.bySender.eq(item.sender)
    if rc.isOk:
      if rc.value.data.sub.eq(item.tx.payload.nonce - 1).isErr:
        debug "invalid tx: account nonces gap",
           txNonce = item.tx.payload.nonce,
           accountNonce
        return false

  true

# ------------------------------------------------------------------------------
# Private function: active tx classifier check helpers
# ------------------------------------------------------------------------------

proc txNonceActive(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [KeyError].} =
  ## Make sure that nonces appear as a contiuous sequence in `staged` bucket
  ## probably preceeded in `packed` bucket.
  let rc = xp.txDB.bySender.eq(item.sender)
  if rc.isErr:
    return true
  # Must not be in the `pending` bucket.
  if rc.value.data.eq(txItemPending).eq(item.tx.payload.nonce - 1).isOk:
    return false
  true


proc txGasCovered(xp: TxPoolRef; item: TxItemRef): bool =
  ## Check whether the max gas consumption is within the gas limit (aka block
  ## size).
  let trgLimit = xp.chain.limits.trgLimit
  if trgLimit < item.tx.payload.gas.GasInt:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = trgLimit,
      gasLimit = item.tx.payload.gas
    return false
  true

proc txFeesCovered(xp: TxPoolRef; item: TxItemRef): bool =
  ## Ensure that the user was willing to at least pay the base fee
  ## And to at least pay the current data gasprice
  if item.tx.payload.tx_type.get(TxLegacy) >= TxEip1559:
    if item.tx.payload.max_fee_per_gas.truncate(int64).GasPriceEx <
        xp.chain.baseFee:
      debug "invalid tx: maxFee is smaller than baseFee",
        maxFee = item.tx.payload.max_fee_per_gas,
        baseFee = xp.chain.baseFee
      return false

  if item.tx.payload.max_fee_per_blob_gas.isSome:
    let
      excessBlobGas = xp.chain.excessBlobGas
      blobGasPrice = getBlobBaseFee(excessBlobGas)
    if item.tx.payload.max_fee_per_blob_gas.unsafeGet < blobGasPrice:
      debug "invalid tx: maxFeePerBlobGas smaller than blobGasPrice",
        maxFeePerBlobGas=item.tx.payload.max_fee_per_blob_gas.unsafeGet,
        blobGasPrice=blobGasPrice
      return false
  true

proc txCostInBudget(xp: TxPoolRef; item: TxItemRef): bool =
  ## Check whether the worst case expense is covered by the price budget,
  let
    balance = xp.chain.getBalance(item.sender)
    gasCost = item.tx.gasCost
  if balance < gasCost:
    debug "invalid tx: not enough cash for gas",
      available = balance,
      require = gasCost
    return false
  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < item.tx.payload.value:
    debug "invalid tx: not enough cash to send",
      available = balance,
      availableMinusGas = balanceOffGasCost,
      require = item.tx.payload.value
    return false
  true


proc txPreLondonAcceptableGasPrice(xp: TxPoolRef; item: TxItemRef): bool =
  ## For legacy transactions check whether minimum gas price and tip are
  ## high enough. These checks are optional.
  if item.tx.payload.tx_type.get(TxLegacy) < TxEip1559:

    if stageItemsPlMinPrice in xp.pFlags:
      if item.tx.payload.max_fee_per_gas.truncate(int64).GasPriceEx <
          xp.pMinPlGasPrice:
        return false

    elif stageItems1559MinTip in xp.pFlags:
      # Fall back transaction selector scheme
       if item.tx.effectiveGasTip(xp.chain.baseFee) < xp.pMinTipPrice:
         return false
  true

proc txPostLondonAcceptableTipAndFees(xp: TxPoolRef; item: TxItemRef): bool =
  ## Helper for `classifyTxPacked()`
  if item.tx.payload.tx_type.get(TxLegacy) >= TxEip1559:

    if stageItems1559MinTip in xp.pFlags:
      if item.tx.effectiveGasTip(xp.chain.baseFee) < xp.pMinTipPrice:
        return false

    if stageItems1559MinFee in xp.pFlags:
      if item.tx.payload.max_fee_per_gas.truncate(int64).GasPriceEx <
          xp.pMinFeePrice:
        return false
  true

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------

proc classifyValid*(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [CatchableError].} =
  ## Check a (typically new) transaction whether it should be accepted at all
  ## or re-jected right away.

  if not xp.checkTxNonce(item):
    return false

  if not xp.checkTxBasic(item):
    return false

  true

proc classifyActive*(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [CatchableError].} =
  ## Check whether a valid transaction is ready to be held in the
  ## `staged` bucket in which case the function returns `true`.

  if not xp.txNonceActive(item):
    return false

  if item.tx.effectiveGasTip(xp.chain.baseFee) <= 0.GasPriceEx:
    return false

  if not xp.txGasCovered(item):
    return false

  if not xp.txFeesCovered(item):
    return false

  if not xp.txCostInBudget(item):
    return false

  if not xp.txPreLondonAcceptableGasPrice(item):
    return false

  if not xp.txPostLondonAcceptableTipAndFees(item):
    return false

  true


proc classifyValidatePacked*(xp: TxPoolRef;
                             vmState: BaseVMState; item: TxItemRef): bool =
  ## Verify the argument `item` against the accounts database. This function
  ## is a wrapper around the `verifyTransaction()` call to be used in a similar
  ## fashion as in `asyncProcessTransactionImpl()`.
  let
    roDB = vmState.readOnlyStateDB
    baseFee = xp.chain.baseFee.uint64.u256
    fork = xp.chain.nextFork
    gasLimit = if packItemsMaxGasLimit in xp.pFlags:
                 xp.chain.limits.maxLimit
               else:
                 xp.chain.limits.trgLimit
    excessBlobGas = calcExcessBlobGas(vmState.parent)

  roDB.validateTransaction(
    item.tx, item.sender, gasLimit, baseFee, excessBlobGas, fork).isOk

proc classifyPacked*(xp: TxPoolRef; gasBurned, moreBurned: GasInt): bool =
  ## Classifier for *packing* (i.e. adding up `gasUsed` values after executing
  ## in the VM.) This function checks whether the sum of the arguments
  ## `gasBurned` and `moreGasBurned` is within acceptable constraints.
  let totalGasUsed = gasBurned + moreBurned
  if packItemsMaxGasLimit in xp.pFlags:
    totalGasUsed < xp.chain.limits.maxLimit
  else:
    totalGasUsed < xp.chain.limits.trgLimit

proc classifyPackedNext*(xp: TxPoolRef; gasBurned, moreBurned: GasInt): bool =
  ## Classifier for *packing* (i.e. adding up `gasUsed` values after executing
  ## in the VM.) This function returns `true` if the packing level is still
  ## low enough to proceed trying to accumulate more items.
  ##
  ## This function is typically called as a follow up after a `false` return of
  ## `classifyPack()`.
  if packItemsTryHarder notin xp.pFlags:
    xp.classifyPacked(gasBurned, moreBurned)
  elif packItemsMaxGasLimit in xp.pFlags:
    gasBurned < xp.chain.limits.hwmLimit
  else:
    gasBurned < xp.chain.limits.lwmLimit

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------
