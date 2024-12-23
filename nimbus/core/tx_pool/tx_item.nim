# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Item Container & Wrapper
## =========================================
##

{.push raises: [].}

import
  std/[hashes, times],
  results,
  ../../utils/utils,
  ../../transaction

from ../eip4844 import getTotalBlobGas
from eth/common/hashes import hash

type
  TxError* = enum
    txErrorInvalidSignature
    txErrorItemNotFound
    txErrorAlreadyKnown
    txErrorNonceTooSmall
    txErrorNonceGap
    txErrorBasicValidation
    txErrorInvalidBlob
    txErrorReplacementGasTooLow
    txErrorReplacementBlobGasTooLow
    txErrorPoolIsFull
    txErrorSenderMaxTxs
    txErrorTxInvalid
    txErrorChainIdMismatch

  TxItemRef* = ref object
    ptx   : PooledTransaction  ## Transaction data
    id    : Hash32             ## Transaction hash
    time  : Time               ## Time when added
    sender: Address            ## Sender account address
    price : GasInt

  TxGasPrice = object
    maxFee: GasInt
    tip: GasInt

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc utcNow*(): Time =
  getTime().utc.toTime

proc new*(T: type TxItemRef;
          ptx: PooledTransaction,
          id: Hash32,
          sender: Address): T =
  ## Create item descriptor.
  T(
    ptx   : ptx,
    id    : id,
    time  : utcNow(),
    sender: sender,
  )

# ------------------------------------------------------------------------------
#  Public functions
# -------------------------------------------------------------------------------

func tip*(tx: Transaction; baseFee: GasInt): GasInt =
  ## Tip calculator
  effectiveGasTip(tx, Opt.some(baseFee.u256))

func txGasPrice*(tx: Transaction): TxGasPrice =
  case tx.txType
  of TxLegacy, TxEip2930:
    TxGasPrice(
      maxFee: tx.gasPrice,
      tip: tx.gasPrice,
    )
  else:
    TxGasPrice(
      maxFee: tx.maxFeePerGas,
      tip: tx.maxPriorityFeePerGas,
    )

func hash*(item: TxItemRef): Hash =
  ## Needed if `TxItemRef` is used as hash-`Table` index.
  hash(item.id)

template pooledTx*(item: TxItemRef): PooledTransaction =
  ## Getter
  item.ptx

template tx*(item: TxItemRef): Transaction =
  ## Getter
  item.ptx.tx

template id*(item: TxItemRef): Hash32 =
  ## Getter
  item.id

template sender*(item: TxItemRef): Address =
  ## Getter
  item.sender

template time*(item: TxItemRef): Time =
  ## Getter
  item.time

template nonce*(item: TxItemRef): AccountNonce =
  ## Getter
  item.tx.nonce

template price*(item: TxItemRef): GasInt =
  ## Getter
  item.price

func calculatePrice*(item: TxItemRef; baseFee: GasInt) =
  ## Profit calculator
  item.price = item.tx.gasLimit * item.tx.tip(baseFee) + item.tx.getTotalBlobGas

func validateTxGasBump*(current: TxItemRef, added: TxItemRef): Result[void, TxError] =
  func txGasPrice(item: TxItemRef): TxGasPrice =
    txGasPrice(item.tx)

  const
    MIN_GAS_PRICE_BUMP_PERCENT = 10

  let
    currentGasPrice = current.txGasPrice
    newGasPrice = added.txGasPrice
    minTipCap = currentGasPrice.tip +
      (currentGasPrice.tip * MIN_GAS_PRICE_BUMP_PERCENT) div 100.GasInt
    minFeeCap = currentGasPrice.maxFee +
      (currentGasPrice.maxFee * MIN_GAS_PRICE_BUMP_PERCENT) div 100.GasInt

  if newGasPrice.tip < minTipCap or newGasPrice.maxFee < minFeeCap:
    return err(txErrorReplacementGasTooLow)

  if added.tx.txType == TxEip4844 and current.tx.txType == TxEip4844:
    let minblobGasFee = current.tx.maxFeePerBlobGas +
      (current.tx.maxFeePerBlobGas * MIN_GAS_PRICE_BUMP_PERCENT.u256) div 100.u256
    if added.tx.maxFeePerBlobGas < minblobGasFee:
      return err(txErrorReplacementBlobGasTooLow)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
