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

import
  ../../../forks,
  ../../../transaction,
  ../tx_chain,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/[common, keys]

{.push raises: [Defect].}

type
  TxPackRc* = enum ##\
    ## Return code for the item packer classifier.
    rcStopPacking     ## done, no more transactions
    rcDoAcceptTx      ## pack this transaction
    rcSkipTx          ## ignore this transaction

logScope:
  topics = "tx-pool classify"

# ------------------------------------------------------------------------------
# Private function: tx validity check helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(xp: TxPoolRef; item: TxItemRef): bool =
  ## Inspired by `p2p/validate.validateTransaction()`
  if item.tx.txType == TxEip2930 and xp.chain.fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if item.tx.txType == TxEip1559 and xp.chain.fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  if item.tx.gasLimit < item.tx.intrinsicGas(xp.chain.fork):
    debug "invalid tx: not enough gas to perform calculation",
      available = item.tx.gasLimit,
      require = item.tx.intrinsicGas(xp.chain.fork)
    return false

  if item.tx.txType != TxLegacy:
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
  let accountNonce = xp.chain.accountNonce(item.sender)

  if item.tx.nonce < accountNonce:
    debug "invalid tx: account nonce too small",
      txNonce = item.tx.nonce,
      accountNonce
    return false

  elif accountNonce < item.tx.nonce:
    # for an existing account, nonces must come in increasing consecutive order
    let rc = xp.txDB.bySender.eq(item.sender)
    if rc.isOK:
      if rc.value.data.any.eq(item.tx.nonce - 1).isErr:
        debug "invalid tx: account nonces gap",
           txNonce = item.tx.nonce,
           accountNonce
        return false

  true

# ------------------------------------------------------------------------------
# Private function: active tx classifier check helpers
# ------------------------------------------------------------------------------

proc txNonceActive(xp: TxPoolRef; item: TxItemRef): bool =
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
  if xp.chain.trgGasLimit < item.tx.gasLimit:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = xp.chain.trgGasLimit,
      gasLimit = item.tx.gasLimit
    return false
  true

proc txFeesCovered(xp: TxPoolRef; item: TxItemRef): bool =
  ## Ensure that the user was willing to at least pay the base fee
  if item.tx.txType != TxLegacy:
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
    balance = xp.chain.accountBalance(item.sender)
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


proc txLegaAcceptableGasPrice(xp: TxPoolRef; item: TxItemRef): bool =
  ## For legacy transactions check whether minimum gas price and tip are
  ## high enough. These checks are optional.
  if item.tx.txType == TxLegacy:

    if stageItemsPlMinPrice in xp.pFlags:
      if item.tx.gasPrice.GasPriceEx < xp.pMinPlGasPrice:
        return false

    elif stageItems1559MinTip in xp.pFlags:
      # Fall back transaction selector scheme
       if item.tx.effectiveGasTip(xp.chain.baseFee) < xp.pMinTipPrice:
         return false
  true

proc txAcceptableTipAndFees(xp: TxPoolRef; item: TxItemRef):  bool =
  ## Helper for `classifyTxPacked()`
  if item.tx.txType != TxLegacy:

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

  if not xp.txLegaAcceptableGasPrice(item):
    return false

  if not xp.txAcceptableTipAndFees(item):
    return false

  true


proc classifyForPacking*(xp: TxPoolRef;
                         item: TxItemRef; gasOffset: GasInt): TxPackRc
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Simple classifier for incremental packing.
  let newTotal = gasOffset + item.tx.gasLimit

  # Note: the following if/else clauses requires that
  #       `xp.chain.trgGasLimit` <= `xp.chain.maxGasLimit `
  #       which is not verified here
  if newTotal <= xp.chain.trgGasLimit:
    return rcDoAcceptTx

  # So the current tx will exceed the soft limit.
  if packItemsTrgGasLimitMax notin xp.pFlags:
    # Required to consider the soft limit `trgGasLimit` as a hard one.
    if packItemsTryHarder in xp.pFlags:
      # Try next one
      return rcSkipTx
    # Done otherwise
    return rcStopPacking

  # So, `packItemsTrgGasLimitMax` is anabled and the soft limit `trgGasLimit`
  # may be exceeded up until the hard limit `maxGasLimit`.
  if newTotal <= xp.chain.maxGasLimit:
    # Accept the first first block exceeding `trgGasLimit`.
    if item.tx.gasLimit <= xp.chain.trgGasLimit:
      return rcDoAcceptTx
    # Done otherwise
    return rcStopPacking

  # Otherwise, this block exceeds the hard limit.
  if packItemsTryHarder in xp.pFlags:
    # Try next one
    return rcSkipTx
  # Done otherwise
  return rcStopPacking

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------
