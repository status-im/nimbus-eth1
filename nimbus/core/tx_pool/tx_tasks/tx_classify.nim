# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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

import ../../../transaction except GasPrice, GasPriceEx  # already in tx_item
import
  ../../../common/common,
  ../../../vm_state,
  ../../../vm_types,
  ../../validate,
  ../tx_chain,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/keys

{.push raises: [Defect].}

logScope:
  topics = "tx-pool classify"

# ------------------------------------------------------------------------------
# Private function: tx validity check helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(xp: TxPoolRef; item: TxItemRef): bool =
  ## Inspired by `p2p/validate.validateTransaction()`
  if item.tx.txType == TxEip2930 and xp.chain.nextFork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if item.tx.txType == TxEip1559 and xp.chain.nextFork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  if item.tx.gasLimit < item.tx.intrinsicGas(xp.chain.nextFork):
    debug "invalid tx: not enough gas to perform calculation",
      available = item.tx.gasLimit,
      require = item.tx.intrinsicGas(xp.chain.nextFork)
    return false

  if item.tx.txType == TxEip1559:
    # The total must be the larger of the two
    if item.tx.maxFee < item.tx.maxPriorityFee:
      debug "invalid tx: maxFee is smaller than maPriorityFee",
        maxFee = item.tx.maxFee,
        maxPriorityFee = item.tx.maxPriorityFee
      return false

  true

proc checkTxNonce(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Make sure that there is only one contiuous sequence of nonces (per
  ## sender) starting at the account nonce.

  # get the next applicable nonce as registered on the account database
  let accountNonce = xp.chain.getNonce(item.sender)

  if item.tx.nonce < accountNonce:
    debug "invalid tx: account nonce too small",
      txNonce = item.tx.nonce,
      accountNonce
    return false

  elif accountNonce < item.tx.nonce:
    # for an existing account, nonces must come in increasing consecutive order
    let rc = xp.txDB.bySender.eq(item.sender)
    if rc.isOk:
      if rc.value.data.any.eq(item.tx.nonce - 1).isErr:
        debug "invalid tx: account nonces gap",
           txNonce = item.tx.nonce,
           accountNonce
        return false

  true

# ------------------------------------------------------------------------------
# Private function: active tx classifier check helpers
# ------------------------------------------------------------------------------

proc txNonceActive(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Make sure that nonces appear as a contiuous sequence in `staged` bucket
  ## probably preceeded in `packed` bucket.
  let rc = xp.txDB.bySender.eq(item.sender)
  if rc.isErr:
    return true
  # Must not be in the `pending` bucket.
  if rc.value.data.eq(txItemPending).eq(item.tx.nonce - 1).isOk:
    return false
  true


proc txGasCovered(xp: TxPoolRef; item: TxItemRef): bool =
  ## Check whether the max gas consumption is within the gas limit (aka block
  ## size).
  let trgLimit = xp.chain.limits.trgLimit
  if trgLimit < item.tx.gasLimit:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = trgLimit,
      gasLimit = item.tx.gasLimit
    return false
  true

proc txFeesCovered(xp: TxPoolRef; item: TxItemRef): bool =
  ## Ensure that the user was willing to at least pay the base fee
  if item.tx.txType == TxEip1559:
    if item.tx.maxFee.GasPriceEx < xp.chain.baseFee:
      debug "invalid tx: maxFee is smaller than baseFee",
        maxFee = item.tx.maxFee,
        baseFee = xp.chain.baseFee
      return false
  true

proc txCostInBudget(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Check whether the worst case expense is covered by the price budget,
  let
    balance = xp.chain.getBalance(item.sender)
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


proc txPreLondonAcceptableGasPrice(xp: TxPoolRef; item: TxItemRef): bool =
  ## For legacy transactions check whether minimum gas price and tip are
  ## high enough. These checks are optional.
  if item.tx.txType != TxEip1559:

    if stageItemsPlMinPrice in xp.pFlags:
      if item.tx.gasPrice.GasPriceEx < xp.pMinPlGasPrice:
        return false

    elif stageItems1559MinTip in xp.pFlags:
      # Fall back transaction selector scheme
       if item.tx.effectiveGasTip(xp.chain.baseFee) < xp.pMinTipPrice:
         return false
  true

proc txPostLondonAcceptableTipAndFees(xp: TxPoolRef; item: TxItemRef): bool =
  ## Helper for `classifyTxPacked()`
  if item.tx.txType == TxEip1559:

    if stageItems1559MinTip in xp.pFlags:
      if item.tx.effectiveGasTip(xp.chain.baseFee) < xp.pMinTipPrice:
        return false

    if stageItems1559MinFee in xp.pFlags:
      if item.tx.maxFee.GasPriceEx < xp.pMinFeePrice:
        return false
  true

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------

proc classifyValid*(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Check a (typically new) transaction whether it should be accepted at all
  ## or re-jected right away.

  if not xp.checkTxNonce(item):
    return false

  if not xp.checkTxBasic(item):
    return false

  true

proc classifyActive*(xp: TxPoolRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,CatchableError].} =
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
  ## fashion as in `processTransactionImpl()`.
  let
    roDB = vmState.readOnlyStateDB
    baseFee = xp.chain.baseFee.uint64.u256
    fork = xp.chain.nextFork
    gasLimit = if packItemsMaxGasLimit in xp.pFlags:
                 xp.chain.limits.maxLimit
               else:
                 xp.chain.limits.trgLimit
    tx = item.tx.eip1559TxNormalization(xp.chain.baseFee.GasInt, fork)

  roDB.validateTransaction(tx, item.sender, gasLimit, baseFee, fork)

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
