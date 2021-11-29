# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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

import
  std/[hashes, sequtils, strutils, times],
  ../ec_recover,
  ../utils_defs,
  ./tx_info,
  eth/[common, keys],
  stew/results

{.push raises: [Defect].}

type
  GasPrice* = ##|
    ## Handy definition distinct from `GasInt` which is a commodity unit while
    ## the `GasPrice` is the commodity valuation per unit of gas, similar to a
    ## kind of currency.
    distinct uint64

  GasPriceEx* = ##\
    ## Similar to `GasPrice` but is allowed to be negative.
    distinct int64

  TxItemStatus* = enum ##\
    ## Current status of a transaction as seen by the pool.
    txItemPending = 0
    txItemStaged
    txItemPacked

  TxItemRef* = ref object of RootObj ##\
    ## Data container with transaction and meta data. Entries are *read-only*\
    ## by default, for some there is a setter available.
    tx:        Transaction           ## Transaction data
    itemID:    Hash256               ## Transaction hash
    timeStamp: Time                  ## Time when added
    sender:    EthAddress            ## Sender account address
    info:      string                ## Whatever
    status:    TxItemStatus          ## Transaction status (setter available)
    reject:    TxInfo                ## Reason for moving to waste basket

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc utcTime: Time =
  getTime().utc.toTime

# ------------------------------------------------------------------------------
# Public helpers supporting distinct types
# ------------------------------------------------------------------------------

proc `$`*(a: GasPrice): string {.borrow.}
proc `<`*(a, b: GasPrice): bool {.borrow.}
proc `<=`*(a, b: GasPrice): bool {.borrow.}
proc `==`*(a, b: GasPrice): bool {.borrow.}
proc `*`*(a, b: GasPrice): GasPrice {.borrow.}
proc `+`*(a, b: GasPrice): GasPrice {.borrow.}
proc `-`*(a, b: GasPrice): GasPrice {.borrow.}

proc `$`*(a: GasPriceEx): string {.borrow.}
proc `<`*(a, b: GasPriceEx): bool {.borrow.}
proc `<=`*(a, b: GasPriceEx): bool {.borrow.}
proc `==`*(a, b: GasPriceEx): bool {.borrow.}
proc `+`*(a, b: GasPriceEx): GasPriceEx {.borrow.}
proc `-`*(a, b: GasPriceEx): GasPriceEx {.borrow.}
proc `+=`*(a: var GasPriceEx; b: GasPriceEx) {.borrow.}
proc `-=`*(a: var GasPriceEx; b: GasPriceEx) {.borrow.}

# mixed stuff

proc `-`*(a: GasPrice; b: SomeUnsignedInt): GasPrice =
  a - b.GasPrice # beware of underflow

proc `*`*(a: SomeUnsignedInt; b: GasPrice): GasPrice =
  (a * b.uint64).GasPrice # beware of overflow

proc `*`*(a: SomeInteger; b: GasPriceEx): GasPriceEx =
  (a * b.int64).GasPriceEx # beware of under/overflow

proc `<`*(a: GasPriceEx|SomeInteger; b: GasPrice): bool =
  if a.GasPriceEx < 0.GasPriceEx: true else: a.GasPrice < b

proc `<`*(a: GasPriceEx; b: SomeInteger): bool =
  a < b.GasPriceEx

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc init*(item: TxItemRef; status: TxItemStatus; info: string) =
  ## Update item descriptor.
  item.info = info
  item.status = status
  item.timeStamp = utcTime()
  item.reject = txInfoOk

proc new*(T: type TxItemRef; tx: Transaction; itemID: Hash256;
          status: TxItemStatus; info: string): Result[T,void] =
  ## Create item descriptor.
  let rc = tx.ecRecover
  if rc.isErr:
    return err()
  ok(T(itemID:    itemID,
       tx:        tx,
       sender:    rc.value,
       timeStamp: utcTime(),
       info:      info,
       status:    status))

proc new*(T: type TxItemRef; tx: Transaction;
          reject: TxInfo; status: TxItemStatus; info: string): T =
  ## Create incomplete item descriptor, so meta-data can be stored (e.g.
  ## for holding in the waste basket to be investigated later.)
  T(tx:        tx,
    timeStamp: utcTime(),
    info:      info,
    status:    status)

# ------------------------------------------------------------------------------
#  Public functions, Table ID helper
# ------------------------------------------------------------------------------

proc hash*(item: TxItemRef): Hash =
  ## Needed if `TxItemRef` is used as hash-`Table` index.
  cast[pointer](item).hash

# ------------------------------------------------------------------------------
# Public functions, transaction getters
# ------------------------------------------------------------------------------

proc itemID*(tx: Transaction): Hash256 =
  ## Getter, transaction ID
  tx.rlpHash

# core/types/transaction.go(239): func (tx *Transaction) Protected() bool {
proc protected*(tx: Transaction): bool =
  ## Getter (go/ref compat): is replay-protected
  if tx.txType == TxLegacy:
    # core/types/transaction.go(229): func isProtectedV(V *big.Int) bool {
    if (tx.V and 255) == 0:
      return tx.V != 27 and tx.V != 28 and tx.V != 1 and tx.V != 0
      # anything not 27 or 28 is considered protected
  true

#  core/types/transaction.go(256): func (tx *Transaction) ChainId() *big.Int {
proc eip155ChainID*(tx: Transaction): ChainID =
  ## Getter (go/ref compat): the EIP155 chain ID of the transaction. For
  ## legacy transactions which are not replay-protected, the return value is
  ## zero.
  if tx.txType != TxLegacy:
    return tx.chainID
  # core/types/transaction_signing.go(510): .. deriveChainId(v *big.Int) ..
  if tx.V != 27 or tx.V != 28:
    return ((tx.V - 35) div 2).ChainID
  # otherwise 0

# # core/types/transaction.go(267): func (tx *Transaction) Gas() uint64 ..
# proc gas*(tx: Transaction): GasInt =
#   ## Getter (go/ref compat): the gas limit of the transaction
#   tx.gasLimit

# core/types/transaction.go(273): func (tx *Transaction) GasTipCap() *big.Int ..
proc gasTipCap*(tx: Transaction): GasPrice =
  ## Getter (go/ref compat): the gasTipCap per gas of the transaction.
  if tx.txType == TxLegacy:
    tx.gasPrice.GasPrice
  else:
    tx.maxPriorityFee.GasPrice

# # core/types/transaction.go(276): func (tx *Transaction) GasFeeCap() ..
# proc gasFeeCap*(tx: Transaction): GasPrice =
#   ## Getter (go/ref compat): the fee cap per gas of the transaction.
#   if tx.txType == TxLegacy:
#     tx.gasPrice.GasPrice
#   else:
#     tx.maxFee.GasPrice

# core/types/transaction.go(297): func (tx *Transaction) Cost() *big.Int {
proc cost*(tx: Transaction): UInt256 =
  ## Getter (go/ref compat): gas * gasPrice + value.
  (tx.gasPrice * tx.gasLimit).u256 + tx.value

# core/types/transaction.go(332): .. *Transaction) EffectiveGasTip(baseFee ..
# core/types/transaction.go(346): .. EffectiveGasTipValue(baseFee ..
proc effectiveGasTip*(tx: Transaction; baseFee: GasPrice): GasPriceEx =
  ## The effective miner gas tip for the globally argument `baseFee`. The
  ## result (which is a price per gas) might well be negative.
  if tx.txType == TxLegacy:
    (tx.gasPrice - baseFee.int64).GasPriceEx
  else:
    # London, EIP1559
    min(tx.maxPriorityFee, tx.maxFee - baseFee.int64).GasPriceEx

proc effectiveGasTip*(tx: Transaction; baseFee: UInt256): GasPriceEx =
  ## Variant of `effectiveGasTip()`
  tx.effectiveGasTip(baseFee.truncate(uint64).GaSPrice)

# ------------------------------------------------------------------------------
# Public functions, item getters
# ------------------------------------------------------------------------------

proc dup*(item: TxItemRef): TxItemRef =
  ## Getter, provide contents copy
  item.deepCopy

proc info*(item: TxItemRef): string =
  ## Getter
  item.info

proc itemID*(item: TxItemRef): Hash256 =
  ## Getter
  item.itemID

proc reject*(item: TxItemRef): TxInfo =
  ## Getter
  item.reject

proc sender*(item: TxItemRef): EthAddress =
  ## Getter
  item.sender

proc status*(item: TxItemRef): TxItemStatus =
  ## Getter
  item.status

proc timeStamp*(item: TxItemRef): Time =
  ## Getter
  item.timeStamp

proc tx*(item: TxItemRef): Transaction =
  ## Getter
  item.tx

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `status=`*(item: TxItemRef; val: TxItemStatus) =
  ## Setter
  item.status = val

proc `reject=`*(item: TxItemRef; val: TxInfo) =
  ## Setter
  item.reject = val

# ------------------------------------------------------------------------------
# Public functions, pretty printing and debugging
# ------------------------------------------------------------------------------

proc `$`*(w: TxItemRef): string =
  ## Visualise item ID (use for debugging)
  "<" & w.itemID.data.mapIt(it.toHex(2)).join[24 .. 31].toLowerAscii & ">"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
