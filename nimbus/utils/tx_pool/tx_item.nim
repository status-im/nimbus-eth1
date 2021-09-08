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
  eth/[common, keys],
  stew/results

type
  TxItemRef* = ref object of RootObj ##\
    ## Data container with transaction and meta data. Entries are *read-only*\
    ## by default, for some there is a setter available.
    tx:        Transaction ## Transaction data
    id:        Hash256     ## Identifier/transaction key
    timeStamp: Time        ## Time when added
    sender:    EthAddress  ## Sender account address
    info:      string      ## Whatever
    local:     bool        ## Local or remote queue (setter available)

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

proc `$`(w: AccessPair): string =
  "(" & $w.address & "," & "#" & $w.storageKeys.len & ")"

proc `$`(q: seq[AccessPair]): string =
  "[" & q.mapIt($it).join(" ") & "]"

# ------------------------------------------------------------------------------
# Public functions, Constructor
# ------------------------------------------------------------------------------

proc newTxItemRef*(tx: Transaction; key: Hash256; local: bool; info: string):
                 Result[TxItemRef,void] =
  ## Create item descriptor.
  let rc = tx.ecRecover
  if rc.isErr:
    return err()
  ok(TxItemRef(
    id:        key,
    tx:        tx,
    sender:    rc.value,
    timeStamp: now().utc.toTime,
    info:      info,
    local:     local))

# ------------------------------------------------------------------------------
#  Public functions, Table ID helper
# ------------------------------------------------------------------------------

proc hash*(item: TxItemRef): Hash =
  ## Needed if `TxItemRef` is used as hash-`Table` index.
  cast[pointer](item).hash

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc id*(item: TxItemRef): auto {.inline.} =
  ## Getter
  item.id

proc tx*(item: TxItemRef): auto {.inline.} =
  ## Getter
  item.tx

proc timeStamp*(item: TxItemRef): auto {.inline.} =
  ## Getter
  item.timeStamp

proc sender*(item: TxItemRef): auto {.inline.} =
  ## Getter
  item.sender

proc info*(item: TxItemRef): auto {.inline.} =
  ## Getter
  item.info

proc local*(item: TxItemRef): auto {.inline.} =
  ## Getter
  item.local

# core/types/transaction.go(239): func (tx *Transaction) Protected() bool {
proc protected*(item: TxItemRef): bool {.inline.} =
  ## Getter (go/ref compat): is replay-protected
  if item.tx.txType == TxLegacy:
    # core/types/transaction.go(229): func isProtectedV(V *big.Int) bool {
    let v = item.tx.V
    if (v and 255) == 0:
      return v != 27 and v != 28 and v != 1 and v != 0
      # anything not 27 or 28 is considered protected
  true

# core/types/transaction.go(267): func (tx *Transaction) Gas() uint64 ..
proc gas*(item: TxItemRef): auto {.inline.} =
  ## Getter (go/ref compat): the gas limit of the transaction
  item.tx.gasLimit

# core/types/transaction.go(270): func (tx *Transaction) Gas() uint64 ..
proc gasPrice*(item: TxItemRef): GasInt {.inline.} =
  ## Getter (go/ref compat): the gas price of the transaction.
  item.tx.gasPrice

# core/types/transaction.go(273): func (tx *Transaction) GasTipCap() *big.Int ..
proc gasTipCap*(item: TxItemRef): GasInt {.inline.} =
  ## Getter (go/ref compat): the gasTipCap per gas of the transaction.
  item.tx.maxPriorityFee

# core/types/transaction.go(276): func (tx *Transaction) GasFeeCap() *big.Int ..
proc gasFeeCap*(item: TxItemRef): GasInt {.inline.} =
  ## GasFeeCap returns the fee cap per gas of the transaction.
  item.tx.maxFee

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `local=`*(item: TxItemRef; val: bool) {.inline.} =
  ## Setter
  item.local = val

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
    ",hash=" & w.id.toXX &
    s[1 ..< s.len]

proc `$`*(w: TxItemRef): string =
  ## Visualise item ID (use for debugging)
  "<" & w.id.toXX & ">"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
