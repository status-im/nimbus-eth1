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
## Current transaction data organisation:
##
## * All incoming transactions are queued (see `rnd_qu` module)
## * Transactions indexed/bucketed by *gas price* (see `slst` module)
##

import
  std/[hashes, sequtils, strformat, strutils, tables, times],
  ./rnd_qu,
  ./slst,
  eth/[common, keys],
  stew/results

export
  results,
  rnd_qu,
  slst

type
  TxInfo* = enum ##\
    ## Error codes (as used in verification function.)
    txOk = 0
    txVfyByIdQueueList      ## Corrupted ID queue/fifo structure
    txVfyByIdQueueKey       ## Corrupted ID queue/fifo container id
    txVfyByGasPriceList     ## Corrupted gas price list structure
    txVfyByGasPriceEntry    ## Corrupted gas price entry queue

  TxItemRef* = ref object of RootObj ##\
    ## Data container with transaction and meta data.
    tx*: Transaction ## Transaction, might be modified
    id: Hash256      ## Identifier/transaction key, read-only
    timeStamp: Time  ## Time when added, read-only
    info: string     ## Whatever, read-only

  TxMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxItemList* = ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    RndQuRef[TxItemRef,TxMark]

  TxIdQueue = ##\
    ## Chronological queue and ID table, fifo
    RndQuRef[Hash256,TxItemRef]

  TxGasPriceInx = ##\
    ## Gas price index list
    SLstRef[GasInt,TxItemList]

  TxPool* = object of RootObj ##\
    ## Transaction pool descriptor
    byIdQueue: TxIdQueue          ## Primary table, queued by arrival event
    byGasPrice: TxGasPriceInx     ## Indexed by gas price

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
# Private, generic list helpers
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
    var dupList = data.value.value
    dupList.del(val)
    if dupList.len == 0:
      discard lst.delete(key)

proc leafDelete[L,K](lst: L; key: K) =
  ## For argument `key` remove all `(key,value)` pairs from list for some
  ## value.
  lst.delete(key)

# ------------------------------------------------------------------------------
# Private, other helpers
# ------------------------------------------------------------------------------

proc hash(itemRef: TxItemRef): Hash =
  ## Needed for the table used in `rnd_qu`
  cast[pointer](itemRef).hash

proc hash(tx: Transaction): Hash256 {.inline.} =
  ## Transaction hash serves as ID
  tx.rlpHash

proc item(rc: RndQuResult[Hash256,TxItemRef]): TxItemRef {.inline.} =
  ## Beware: rc.isOK must hold
  rc.value.value

proc itemResult(rc: RndQuResult[Hash256,TxItemRef]): Result[TxItemRef,void] =
  if rc.isErr:
    return err()
  return ok(rc.value.value)

# ------------------------------------------------------------------------------
# Private, explicit list & queue helpers
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


proc newIdQueue(): auto =
  newRndQu[Hash256,TxItemRef]()

proc verifyByIdQueue(xp: TxPool): RndQuInfo
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = xp.byIdQueue.verify
  if rc.isErr:
    return rc.error[2]
  rndQuOk

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc initTxPool*(): TxPool =
  ## Constructor, returns new tx-pool descriptor.
  TxPool(
    byIdQueue:  newIdQueue(),
    byGasPrice: newGasPriceInx())

# ------------------------------------------------------------------------------
# Public functions, add/remove entry
# ------------------------------------------------------------------------------

proc insert*(xp: var TxPool; tx: Transaction; info = ""): Result[Hash256,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add new transaction argument `tx` to the database. If accepted and added
  ## to the database, a `key` value is returned which can be used to retrieve
  ## this transaction direcly via `tx[key].tx`. The following holds for the
  ## returned `key` value (see `[]` below for details):
  ## ::
  ##   xp[key].id == key  # id: transaction key stored in the wrapping container
  ##   tx.toKey == key    # holds as long as tx is not modified
  ##
  ## Adding the transaction will be rejected if the transaction key `tx.toKey`
  ## exists in the database already.
  ##
  ## CAVEAT:
  ##   The returned transaction key `key` for the transaction `tx` is
  ##   recoverable as `tx.toKey` only while the trasaction remains unmodified.
  ##
  let key = tx.hash
  if xp.byIdQueue.hasKey(key):
    return err()
  let item = TxItemRef(
    id:        key,
    tx:        tx,
    timeStamp: getTime(),
    info:      info)
  xp.byIdQueue[key] = item
  xp.insertByGasPrice(item.tx.gasPrice, item)
  return ok(key)

proc delete*(xp: var TxPool; key: Hash256): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Delete transaction (and wrapping container) from the database. If
  ## successful, the function returns the wrapping container that was just
  ## removed.
  let rc = xp.byIdQueue.delete(key)
  if rc.isErr:
    return err()
  let item = rc.item
  xp.deleteByGasPrice(item.tx.gasPrice, item)
  return ok(item)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(xp: var TxPool): int =
  ## Total number of registered transactions
  xp.byIdQueue.len

proc len*(rq: TxItemList): int =
  ## Returns the number of items on the argument queue `rq` which is typically
  ## the result of an `SLstRef` type object query holding one or more
  ## duplicates relative to the same index.
  rnd_qu.len(rq)

proc byGasPriceLen*(xp: var TxPool): int =
  ## Number of different gas prices known. Fo each gas price there is at least
  ## one transaction available.
  xp.byGasPrice.len

proc id*(item: TxItemRef): Hash256 {.inline.} =
  ## Getter
  item.id

proc timeStamp*(item: TxItemRef): Time {.inline.} =
  ## Getter
  item.timeStamp

proc info*(item: TxItemRef): string {.inline.} =
  ## Getter
  item.info

# ------------------------------------------------------------------------------
# Public functions, ID queue query
# ------------------------------------------------------------------------------

proc hasKey*(xp: var TxPool; key: Hash256): bool =
  ## Returns `true` if the argument `key` for a transaction exists in the
  ## database, already. If this function returns `true`, then it is save to
  ## use the `xp[key]` paradigm for accessing a transaction container.
  xp.byIdQueue.hasKey(key)

proc toKey*(tx: Transaction): Hash256 {.inline.} =
  ## Retrieves transaction key. Note that the returned argument will only apply
  ## to a transaction in the database if the argument transaction `tx` is
  ## exactly the same as the one passed earlier to the `insert()` function.
  tx.hash

proc `[]`*(xp: var TxPool; key: Hash256): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## If it exists, this function retrieves a transaction container `item`
  ## for the argument `key` with
  ## ::
  ##   item.id == key
  ##
  ## See also commments on `toKey()` and `insert()`.
  ##
  ## Note that the underlying *tables* module may throw a `KeyError` exception
  ## unless the argument `key` exists in the database.
  xp.byIdQueue[key]

proc oldest*(xp: var TxPool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves oldest item queued (if any): first fifo output item
  xp.byIdQueue.first.itemResult

proc newest*(xp: var TxPool): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Retrieves newest item queued (if any): last fifo input item
  xp.byIdQueue.last.itemResult

iterator firstOutItems*(xp: var TxPool): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## ID queue walk/traversal: oldest first (fifo).
  ##
  ## Note: When running in a loop it is ok to delete the current item and
  ## the all items already visited. Items not visited yet must not be deleted.
  var rc = xp.byIdQueue.first
  while rc.isOK:
    let item = rc.item
    rc = xp.byIdQueue.next(rc.value)
    yield item

iterator lastInItems*(xp: var TxPool): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## ID queue walk/traversal: newest first (lifo)
  ##
  ## Note: When running in a loop it is ok to delete the current item and
  ## the all items already visited. Items not visited yet must not be deleted.
  var rc = xp.byIdQueue.last
  while rc.isOK:
    let item = rc.item
    rc = xp.byIdQueue.prev(rc.value)
    yield item

# ------------------------------------------------------------------------------
# Public functions, gas price query
# ------------------------------------------------------------------------------

proc byGasPriceGe*(xp: var TxPool; gWei: GasInt): Result[TxItemList,void] =
  ## Retrieve the list of transaction records all with the same *least* gas
  ## price *greater or equal* the argument `gWei`. On success, the resulting
  ## list of transactions has at least one item.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  let rc = xp.byGasPrice.ge(gWei)
  if rc.isOk:
    return ok(rc.value.value)
  err()

proc byGasPriceGt*(xp: var TxPool; gWei: GasInt): Result[TxItemList,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.gt(gWei)
  if rc.isOk:
    return ok(rc.value.value)
  err()

proc byGasPriceLe*(xp: var TxPool; gWei: GasInt): Result[TxItemList,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.le(gWei)
  if rc.isOk:
    return ok(rc.value.value)
  err()

proc byGasPriceLt*(xp: var TxPool; gWei: GasInt): Result[TxItemList,void] =
  ## Similar to `byGasPriceGe()`.
  let rc = xp.byGasPrice.lt(gWei)
  if rc.isOk:
    return ok(rc.value.value)
  err()

iterator byGasPriceIncPairs*(xp: var TxPool;
                             gWei = GasInt.low): (GasInt,TxItemList) =
  ## Starting at the lowest, this function traverses increasing gas prices.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  ##
  ## Note: When running in a loop it is ok to add or delete any entries
  ## vistied or not visited yet.
  var rc = xp.byGasPrice.ge(gWei)
  while rc.isOk:
    let yKey = rc.value.key
    yield (ykey, rc.value.value)
    rc = xp.byGasPrice.gt(ykey)

iterator byGasPriceDecPairs*(xp: var TxPool;
                             gWei = GasInt.high): (GasInt,TxItemList) =
  ## Starting at the highest, this function traverses decreasing gas prices.
  ##
  ## While the returned *list* of transaction containers *must not* be modified
  ## directly, a transaction entry within a container may well be altered.
  ##
  ## Note: When running in a loop it is ok to add or delete any entries
  ## vistied or not visited yet.
  var rc = xp.byGasPrice.le(gWei)
  while rc.isOk:
    let yKey = rc.value.key
    yield (yKey, rc.value.value)
    rc = xp.byGasPrice.lt(yKey)

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
    &",hash=" & w.id.toXX &
    s[1 ..< s.len]

proc `$`*(w: TxItemRef): string =
  ## Visualise item ID (use for debugging)
  "<" & w.id.toXX & ">"

proc verify*(xp: var TxPool): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.
  block:
    let rc = xp.verifyByGasPrice
    if rc != rbOK:
      return err(txVfyByGasPriceList)
    for (key,lst) in xp.byGasPriceIncPairs:
      if lst.len == 0:
        return err(txVfyByGasPriceEntry)

  block:
    let rc = xp.verifyByIdQueue
    if rc != rndQuOk:
      return err(txVfyByIdQueueList)
    for item in xp.firstOutItems:
      if item.id != xp[item.id].id:
        return err(txVfyByIdQueueKey)

  return ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
