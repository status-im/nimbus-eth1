# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool
## ================
##

import
  std/[hashes, sequtils, strformat, strutils, tables, times],
  ./rnd_qu,
  ./slst,
  eth/[common, keys],
  stew/results

type
  TxItemRef* = ref object of RootObj ##\
    tx*: Transaction ## Transaction, might be modified
    id: Hash256      ## Identifier, read-only
    timeStamp: Time  ## Time when added, read-only
    info: string     ## Whatever, read-only

  TxMark* = ##\
    ## Ready to be used for something, currently just a blind value
    ## that comes with the `RndQuItemRef` value
    int

  TxItemList* = ##\
    ## Chronologically ordered queue with random access
    RndQuRef[TxItemRef,TxMark]

  TxResultItems* = ##\
    ## Typcal function result
    Result[TxItemList,void]

  TxTimeStampInx = ##\
    ## Time stamp index list
    SLstRef[Time,TxItemList]

  TxGasPriceInx = ##\
    ## Gas price index list
    SLstRef[GasInt,TxItemList]

  TxPool* = object of RootObj ##\
    ## ..
    tab: Table[Hash256,TxItemRef] ## Primary transaction table
    byGasPrice: TxGasPriceInx     ## Indexed by gas price
    byTimeStamp: TxTimeStampInx   ## Indexed by insertion timeStamp

{.push raises: [Defect].}

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

proc `$`(rq: TxItemList): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.len

# ------------------------------------------------------------------------------
# Private, generic helpers
# ------------------------------------------------------------------------------

proc leafInsert[L,K](lst: L; key: K; val: TxItemRef)
                       {.gcsafe,raises: [Defect,KeyError].} =
  ## Unconitionally add `(key,val)` pair to list. This might lead to
  ## multiple leaf values per argument `key`.
  var data = lst.insert(key)
  if data.isOk:
    data.value.value = newRndQu[TxItemRef,TxMark](1)
  else:
    data = lst.eq(key)
  discard data.value.value.append(val)

proc leafDelete[L,K](lst: L; key: K; val: TxItemRef)
                       {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove `(key,val)` pair from list.
  var data = lst.eq(key)
  if data.isOk:
    discard data.value.value.delete(val)

proc leafDelete[L,K](lst: L; key: K) =
  ## For argument `key` remove all `(key,value)` pairs from list for some
  ## value.
  lst.delete(key)

proc hash(val: TxItemRef): Hash =
  ## Needed for the table used in `rnd_qu`
  cast[pointer](val).hash

# ------------------------------------------------------------------------------
# Private, explicit helpers
# ------------------------------------------------------------------------------

proc newGasPriceInx(): auto =
  newSLst[GasInt,TxItemList]()

proc insertByGasPrice(xp: TxPool; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  xp.byGasPrice.leafInsert(key,val)

proc deleteByGasPrice(xp: TxPool; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  xp.byGasPrice.leafDelete(key,val)

proc verifyByGasPrice(xp: TxPool): RbInfo
    {.gcsafe, raises: [Defect,CatchableError].} =
  let rc = xp.byGasPrice.verify
  if rc.isErr:
    return rc.error[1]


proc newTimeStampInx(): auto =
  newSLst[Time,TxItemList]()

proc insertByTimeStamp(xp: TxPool; key: Time; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  xp.byTimeStamp.leafInsert(key,val)

proc deleteByTimeStamp(xp: TxPool; key: Time; val: TxItemRef)
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  xp.byTimeStamp.leafDelete(key,val)

proc verifyByTimeStamp(xp: TxPool): RbInfo
    {.gcsafe, raises: [Defect,CatchableError].} =
  let rc = xp.byTimeStamp.verify
  if rc.isErr:
    return rc.error[1]

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc initTxPool*(): TxPool =
  TxPool(
    # tab: no-init-needed
    byGasPrice:  newGasPriceInx(),
    byTimeStamp: newTimeStampInx())

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(xp: var TxPool; tx: Transaction; info = ""): bool
    {.discardable,gcsafe,raises: [Defect,KeyError].} =
  let item = TxItemRef(
    id:        tx.rlpHash,
    tx:        tx,
    timeStamp: getTime(),
    info:      info)
  if not xp.tab.hasKey(item.id):
    xp.tab[item.id] = item
    xp.insertByGasPrice(item.tx.gasPrice,item)
    xp.insertByTimeStamp(item.timeStamp,item)
    return true

proc delete*(xp: var TxPool; hash: Hash256): bool
    {.discardable,gcsafe,raises: [Defect,KeyError].} =
  if xp.tab.hasKey(hash):
    let item = xp.tab[hash]
    xp.tab.del(item.id)
    xp.deleteByGasPrice(item.tx.gasPrice,item)
    xp.deleteByTimeStamp(item.timeStamp,item)
    return true

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(xp: var TxPool): int =
  ## Total number of registered transactions
  xp.tab.len

proc len*(rq: TxItemList): int =
  ## Returns the number of items in the list
  rnd_qu.len(rq)

proc byGasPriceLen*(xp: var TxPool): int =
  ## Number of different gas prices
  xp.byGasPrice.len

proc byTimeStampLen*(xp: var TxPool): int =
  ## Number of different time stamp (should be pretty much the same as
  ## `xp.len`)
  xp.byTimeStamp.len

proc id*(w: TxItemRef): Hash256 {.inline.} =
  ## Getter
  w.id

proc timeStamp*(w: TxItemRef): Time {.inline.} =
  ## gGetter
  w.timeStamp

proc info*(w: TxItemRef): string {.inline.} =
  ## gGetter
  w.info

# ------------------------------------------------------------------------------
# Public functions, fetch data
# ------------------------------------------------------------------------------

proc byGasPriceGe*(xp: var TxPool; gWei: GasInt): TxResultItems =
  ## Retrieve the list of transaction records with the *least* gas price
  ## *greater or equal* the argument `gWei`. On success, the resulting
  ## list of transactions has at least one item.
  ##
  ## While the returned list *must not* be modified, the transaction entries
  ## in the list may well be altered.
  let rc = xp.byGasPrice.ge(gWei)
  if rc.isOk:
    doAssert 0 < rc.value.value.len
    return ok(rc.value.value)
  err()

proc byGasPriceGt*(xp: var TxPool; gWei: GasInt): TxResultItems =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.gt(gWei)
  if rc.isOk:
    doAssert 0 < rc.value.value.len
    return ok(rc.value.value)
  err()

proc byGasPriceLe*(xp: var TxPool; gWei: GasInt): TxResultItems =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.le(gWei)
  if rc.isOk:
    doAssert 0 < rc.value.value.len
    return ok(rc.value.value)
  err()

proc byGasPriceLt*(xp: var TxPool; gWei: GasInt): TxResultItems =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.lt(gWei)
  if rc.isOk:
    doAssert 0 < rc.value.value.len
    return ok(rc.value.value)
  err()

# ------------------------------------------------------------------------------
# Public functions, query functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public functions, walk/traversal functions
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# Public functions, pretty printing and debugging
# ------------------------------------------------------------------------------

proc pp*(tx: Transaction): string =

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
  let s = w.tx.pp
  result = "(timeStamp=" & ($w.timeStamp).replace(' ','_') &
    &",hash=" & w.id.toXX &
    s[1 ..< s.len]

proc `$`*(w: TxItemRef): string =
  "<" & w.id.toXX & ">"

proc verify*(xp: var TxPool): bool
    {.gcsafe, raises: [Defect,CatchableError].} =
  var rc = xp.verifyByGasPrice
  if rc != rbOK:
    return false

  rc = xp.verifyByTimeStamp
  if rc != rbOK:
    return false

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
