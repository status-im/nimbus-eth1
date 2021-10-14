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

type
  GasPrice* = ##|
    ## Handy definition distinct from `GasInt` which is a commodity while the\
    ## `GasPrice` is the value per unit of gas, similar to a kind of money.
    distinct uint64

  GasPriceEx* = ##\
    ## Similar to `GasPrice` but is allowed to be negative.
    distinct int64

  TxItemStatus* = enum ##\
    ## current status of a transaction as seen by the pool.
    txItemQueued = 0
    txItemPending
    txItemStaged

  TxItemRef* = ref object of RootObj ##\
    ## Data container with transaction and meta data. Entries are *read-only*\
    ## by default, for some there is a setter available.
    tx:        Transaction  ## Transaction data
    itemID:    Hash256      ## Transaction hash
    timeStamp: Time         ## Time when added
    sender:    EthAddress   ## Sender account address
    info:      string       ## Whatever
    status:    TxItemStatus ## Transaction status (setter available)
    effGasTip: GasPriceEx   ## Effective gas tip value
    reject:    TxInfo       ## Reason for moving to waste basket

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc joinXX(s: string): string =
  if s.len <= 30:
    return s
  if (s.len and 1) == 0:
    result = s[0 ..< 8]
  else:
    result = "0" & s[0 ..< 7]
  result &= "..(" & $((s.len + 1) div 2) & ").." & s[s.len-16 ..< s.len]

proc joinXX(q: seq[string]): string =
  q.join("").joinXX

proc toXX[T](s: T): string =
  s.toHex.strip(leading=true,chars={'0'}).toLowerAscii

proc toXX(q: Blob): string =
  q.mapIt(it.toHex(2)).join(":")

proc toXX(a: EthAddress): string =
  a.mapIt(it.toHex(2)).joinXX

proc toXX(h: Hash256): string =
  h.data.mapIt(it.toHex(2)).joinXX

proc toXX(v: int64; r,s: UInt256): string =
  v.toXX & ":" & ($r).joinXX & ":" & ($s).joinXX

proc toKMG[T](s: T): string =
  proc subst(s: var string; tag, new: string): bool =
    if tag.len < s.len and s[s.len - tag.len ..< s.len] == tag:
      s = s[0 ..< s.len - tag.len] & new
      return true
  result = $s
  for w in [("000", "K"),("000K","M"),("000M","G"),("000G","T"),
            ("000T","P"),("000P","E"),("000E","Z"),("000Z","Y")]:
    if not result.subst(w[0],w[1]):
      return

proc pp(w: TxItemStatus): string =
  ($w).replace("txItem")

proc `$`(w: AccessPair): string =
  "(" & $w.address & "," & "#" & $w.storageKeys.len & ")"

proc `$`(q: seq[AccessPair]): string =
  "[" & q.mapIt($it).join(" ") & "]"

# ------------------------------------------------------------------------------
# Public helpers supporting distinct types
# ------------------------------------------------------------------------------

proc `$`*(a: GasPrice): string {.borrow.}
proc `<`*(a, b: GasPrice): bool {.borrow.}
proc `<=`*(a, b: GasPrice): bool {.borrow.}
proc `==`*(a, b: GasPrice): bool {.borrow.}
proc `+`*(a, b: GasPrice): GasPrice {.borrow.}
proc `-`*(a, b: GasPrice): GasPrice {.borrow.}

proc `-`*(a: GasPrice; b: int): GasPrice =
  a - b.GasPrice # beware of underflow

proc `$`*(a: GasPriceEx): string {.borrow.}
proc `<`*(a, b: GasPriceEx): bool {.borrow.}
proc `<=`*(a, b: GasPriceEx): bool {.borrow.}
proc `==`*(a, b: GasPriceEx): bool {.borrow.}
proc `+`*(a, b: GasPriceEx): GasPriceEx {.borrow.}
proc `-`*(a, b: GasPriceEx): GasPriceEx {.borrow.}

proc `<`*(a: GasPriceEx|int; b: GasPrice): bool =
  if a.GasPriceEx < 0.GasPriceEx: true else: a.GasPrice < b

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------


proc newTxItemRef*(tx: Transaction;
                   itemID: Hash256; status: TxItemStatus; info: string):
                 Result[TxItemRef,void] {.inline.} =
  ## Create item descriptor.
  let rc = tx.ecRecover
  if rc.isErr:
    return err()
  ok(TxItemRef(
    itemID:    itemID,
    tx:        tx,
    sender:    rc.value,
    timeStamp: now().utc.toTime,
    info:      info,
    status:    status))

proc newTxItemRef*(tx: Transaction;
                   reject: TxInfo; status: TxItemStatus; info: string):
                     TxItemRef {.inline.} =
  ## Create incomplete item descriptor, so meta-data can be stored (e.g.
  ## for holding in the waste basket to be investigated later.)
  TxItemRef(
    tx:        tx,
    timeStamp: now().utc.toTime,
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

proc itemID*(tx: Transaction): Hash256 {.inline.} =
  ## Getter, transaction ID
  tx.rlpHash

# core/types/transaction.go(239): func (tx *Transaction) Protected() bool {
proc protected*(tx: Transaction): bool {.inline.} =
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
# proc gas*(tx: Transaction): GasInt {.inline.} =
#   ## Getter (go/ref compat): the gas limit of the transaction
#   tx.gasLimit

# core/types/transaction.go(273): func (tx *Transaction) GasTipCap() *big.Int ..
proc gasTipCap*(tx: Transaction): GasPrice {.inline.} =
  ## Getter (go/ref compat): the gasTipCap per gas of the transaction.
  if tx.txType == TxLegacy:
    tx.gasPrice.GasPrice
  else:
    tx.maxPriorityFee.GasPrice

# # core/types/transaction.go(276): func (tx *Transaction) GasFeeCap() ..
# proc gasFeeCap*(tx: Transaction): GasPrice {.inline.} =
#   ## Getter (go/ref compat): the fee cap per gas of the transaction.
#   if tx.txType == TxLegacy:
#     tx.gasPrice.GasPrice
#   else:
#     tx.maxFee.GasPrice

# core/types/transaction.go(297): func (tx *Transaction) Cost() *big.Int {
proc cost*(tx: Transaction): UInt256 {.inline.} =
  ## Getter (go/ref compat): gas * gasPrice + value.
  (tx.gasPrice * tx.gasLimit).u256 + tx.value

proc estimatedGasTip*(tx: Transaction;
                      baseFee: GasPrice): GasPriceEx {.inline.} =
  ## The effective miner gas tip for the globally argument `baseFee`. The
  ## result (which is a price per gas) might well be negative.
  if tx.txType == TxLegacy:
    (tx.gasPrice - baseFee.int64).GasPriceEx
  else:
    # London, EIP1559
    min(tx.maxPriorityFee, tx.maxFee - baseFee.int64).GasPriceEx

# ------------------------------------------------------------------------------
# Public functions, item getters
# ------------------------------------------------------------------------------

proc dup*(item: TxItemRef): TxItemRef {.inline.} =
  ## Getter, provide contents copy
  item.deepCopy

proc itemID*(item: TxItemRef): Hash256 {.inline.} =
  ## Getter
  item.itemID

proc tx*(item: TxItemRef): Transaction {.inline.} =
  ## Getter
  item.tx

proc timeStamp*(item: TxItemRef): Time {.inline.} =
  ## Getter
  item.timeStamp

proc sender*(item: TxItemRef): EthAddress {.inline.} =
  ## Getter
  item.sender

proc info*(item: TxItemRef): string {.inline.} =
  ## Getter
  item.info

proc local*(item: TxItemRef): bool {.inline.} =
  ## Getter
  item.local

proc status*(item: TxItemRef): TxItemStatus {.inline.} =
  ## Getter
  item.status

proc effGasTip*(item: TxItemRef): GasPriceEx {.inline.} =
  ## Getter, this is typically the cached value of `estimatedGasTip()` for
  ## a given `baseFee`
  item.effGasTip

proc reject*(item: TxItemRef): TxInfo {.inline.} =
  ## Getter
  item.reject

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `local=`*(item: TxItemRef; val: bool) {.inline.} =
  ## Setter
  item.local = val

proc `status=`*(item: TxItemRef; val: TxItemStatus) {.inline.} =
  ## Setter
  item.status = val

proc `effGasTip=`*(item: TxItemRef; val: GasPriceEx) {.inline.} =
  ## Setter
  item.effGasTip = val

proc `reject=`*(item: TxItemRef; val: TxInfo) {.inline.} =
  ## Setter
  item.reject = val

# ------------------------------------------------------------------------------
# Public functions, pretty printing and debugging
# ------------------------------------------------------------------------------

proc pp*(tx: Transaction): string =
  ## Pretty print transaction (use for debugging)
  result = "(txType=" & $tx.txType

  if tx.chainId.uint64 != 0:
    result &= ",chainId=" & $tx.chainId.uint64

  result &= ",nonce=" & tx.nonce.toXX
  if tx.gasPrice != 0:
    result &= ",gasPrice=" & tx.gasPrice.toKMG
  if tx.maxPriorityFee != 0:
    result &= ",maxPrioFee=" & tx.maxPriorityFee.toKMG
  if tx.maxFee != 0:
    result &= ",maxFee=" & tx.maxFee.toKMG
  if tx.gasLimit != 0:
    result &= ",gasLimit=" & tx.gasLimit.toKMG
  if tx.to.isSome:
    result &= ",to=" & tx.to.get.toXX
  if tx.value != 0:
    result &= ",value=" & tx.value.toKMG
  if 0 < tx.payload.len:
    result &= ",payload=" & tx.payload.toXX
  if 0 < tx.accessList.len:
    result &= ",accessList=" & $tx.accessList

  result &= ",VRS=" & tx.V.toXX(tx.R,tx.S)
  result &= ")"

proc pp*(w: TxItemRef): string =
  ## Pretty print item (use for debugging)
  let s = w.tx.pp
  result = "(timeStamp=" & ($w.timeStamp).replace(' ','_') &
    ",hash=" & w.itemID.toXX &
    ",status=" & w.status.pp &
    "," & s[1 ..< s.len]

proc `$`*(w: TxItemRef): string =
  ## Visualise item ID (use for debugging)
  "<" & w.itemID.toXX & ">"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
