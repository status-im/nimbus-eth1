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
  ../../../db/accounts_cache,
  ../../../forks,
  ../../../transaction,
  ../../sorted_set,
  ../tx_dbhead,
  ../tx_desc,
  ../tx_item,
  ../tx_tabs,
  chronicles,
  eth/[common, keys]

type
  TxClassify* = object ##\
    ## Classifier arguments, typically cached values which might be
    ## controlled somewhere else.
    stageSelect*: set[TxPoolAlgoSelectorFlags] ## Packer strategy symbols

    minFeePrice*: GasPrice   ## Gas price enforced by the pool, `gasFeeCap`
    minTipPrice*: GasPrice   ## Desired tip-per-tx target, `estimatedGasTip`
    minPlGasPrice*: GasPrice ## pre-London minimum gas prioce
    baseFee*: GasPrice       ## Current base fee

    gasLimit*: GasInt        ## Block size limit

#[
const
  dedicatedSender* = block:
    var rc: EthAddress
    const
      a = [140,30,30,91,71,152,13,33,73,101,243,189,142,163,76,65,62,18,10,228]
    for n in 0 ..< rc.len:
      rc[n] = a[n].byte
    rc
]#

logScope:
  topics = "tx-pool classify transaction"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private function: validity check helpers
# ------------------------------------------------------------------------------

proc checkTxBasic(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Inspired by `p2p/validate.validateTransaction()`
  if item.tx.txType == TxEip2930 and xp.dbHead.fork < FkBerlin:
    debug "invalid tx: Eip2930 Tx type detected before Berlin"
    return false

  if item.tx.txType == TxEip1559 and xp.dbHead.fork < FkLondon:
    debug "invalid tx: Eip1559 Tx type detected before London"
    return false

  if item.tx.gasLimit < item.tx.intrinsicGas(xp.dbHead.fork):
    debug "invalid tx: not enough gas to perform calculation",
      available = item.tx.gasLimit,
      require = item.tx.intrinsicGas(xp.dbHead.fork)
    return false

  if item.tx.txType != TxLegacy:
    # The total must be the larger of the two
    if item.tx.maxFee < item.tx.maxPriorityFee:
      debug "invalid tx: maxFee is smaller than maPriorityFee",
        maxFee = item.tx.maxFee,
        maxPriorityFee = item.tx.maxPriorityFee
      return false

  true

proc checkTxNonce(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Make sure that there is only one contiuous sequence of nonces (per
  ## sender) starting at the account nonce.

  # get the next applicable nonce as registered on the account database
  let accountNonce = ReadOnlyStateDB(xp.dbHead.accDb).getNonce(item.sender)

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
# Private function: staged classifier check helpers
# ------------------------------------------------------------------------------

proc txNonceInStagedSequence(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Make sure that nonces appear as a contiuous sequence in `staged` bucket
  ## probably preceeded in `packed` bucket.
  let rc = xp.txDB.bySender.eq(item.sender)
  if rc.isErr:
    return true
  # Must not be in the `pending` bucket.
  if rc.value.data.eq(txItemPending).eq(item.tx.nonce - 1).isOk:
    return false
  true

proc txNonceInPackedSequence(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Make sure that nonces appear as a contiuous sequence in `packed` bucket.
  let rc = xp.txDB.bySender.eq(item.sender)
  if rc.isErr:
    return true
  # Must neither be in `pending` nor `staged` bucket.
  if rc.value.data.eq(txItemPending).eq(item.tx.nonce - 1).isOk:
    return false
  if rc.value.data.eq(txItemStaged).eq(item.tx.nonce - 1).isOk:
    return false
  true


proc txGasCovered(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Check whether the max gas consumption is within the gas limit (aka block
  ## size).
  if param.gasLimit < item.tx.gasLimit:
    debug "invalid tx: gasLimit exceeded",
      maxLimit = param.gasLimit,
      gasLimit = item.tx.gasLimit
    return false
  true

proc txFeesCovered(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Ensure that the user was willing to at least pay the base fee
  if item.tx.txType != TxLegacy:
    if item.tx.maxFee.GasPriceEx < param.baseFee:
      debug "invalid tx: maxFee is smaller than baseFee",
        maxFee = item.tx.maxFee,
        baseFee = param.baseFee
      return false
  true

proc txCostInBudget(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## Check whether the worst case expense is covered by the price budget,
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


proc txLegaAcceptableGasPrice(
    xp: TxPoolRef; item: TxItemRef; param: TxClassify): bool {.inline.} =
  ## For legacy transactions check whether minimum gas price and tip are
  ## high enough. These checks are optional.
  if item.tx.txType == TxLegacy:

    if algoPackedPlMinPrice in param.stageSelect:
      if item.tx.gasPrice.GasPriceEx < param.minPlGasPrice:
        return false

    elif algoPacked1559MinTip in param.stageSelect:
      # Fall back transaction selector scheme
       if item.effGasTip < param.minTipPrice:
         return false
  true

proc txAcceptableTipAndFees(
     xp: TxPoolRef; item: TxItemRef; param: TxClassify):  bool {.inline.}=
  ## Helper for `classifyTxPacked()`
  if item.tx.txType != TxLegacy:

    if algoPacked1559MinTip in param.stageSelect:
      if item.effGasTip < param.minTipPrice:
        return false

    if algoPacked1559MinFee in param.stageSelect:
      if item.tx.maxFee.GasPriceEx < param.minFeePrice:
        return false
  true

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------

proc classifyTxValid*(xp: TxPoolRef;
                      item: TxItemRef; param: TxClassify): bool =
  ## Check a (typically new) transaction whether it should be accepted at all
  ## or re-jected right away.

  if not xp.checkTxBasic(item,param):
    return false

  if not xp.checkTxNonce(item,param):
    return false

  true


proc classifyTxStaged*(xp: TxPoolRef;
                       item: TxItemRef; param: TxClassify): bool =
  ## Check whether a valid transaction is ready to be moved to the
  ## `staged` bucket, otherwise it will go to the `pending` bucket.

  if not xp.txNonceInStagedSequence(item,param):
    return false

  if item.tx.estimatedGasTip(param.baseFee) <= 0.GasPriceEx:
    return false

  if not xp.txGasCovered(item,param):
    return false

  if not xp.txFeesCovered(item,param):
    return false

  if not xp.txCostInBudget(item,param):
    return false

  if not xp.txLegaAcceptableGasPrice(item, param):
    return false

  if not xp.txAcceptableTipAndFees(item, param):
    return false

  true


# ---- obsolete ----

proc classifyTxPacked*(xp: TxPoolRef;
                       item: TxItemRef; param: TxClassify): bool =
  ## Check whether a `staged` transaction is ready to be moved to the
  ## `packed` bucket, otherwise it will go to the `pending` bucket to start
  ## all over.
  if item.tx.txType == TxLegacy:
    xp.txLegaAcceptableGasPrice(item, param)
  else:
    xp.txAcceptableTipAndFees(item, param)

# ------------------------------------------------------------------------------
# Public functionss
# ------------------------------------------------------------------------------
