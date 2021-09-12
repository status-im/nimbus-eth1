# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Price List
## ===========================
##
## Sorter: `gasPrice` > `AccountNonce` > fifo
##

import
  ../keequ,
  ../slst,
  ./tx_item,
  eth/common,
  stew/results

type
  TxPriceInfo* = enum
    txPriceOk = 0
    txPriceVfyRbTree    ## Corrupted RB tree
    txPriceVfyLeafEmpty ## Empty leaf list
    txPriceVfyLeafQueue ## Corrupted leaf list
    txPriceVfySize      ## Size count mismatch

  TxPriceMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxPriceItemRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    itemList*: KeeQu[TxItemRef,TxPriceMark]

  TxPriceNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    size: int
    nonceList*: Slst[AccountNonce,TxPriceItemRef]

  TxPriceItems* = object ##\
    ## Item list indexed by `GasPrice` > `AccountNonce`
    size: int
    priceList: SLst[GasInt,TxPriceNonceRef]

  TxPriceInx = object ##\
    ## Internal access data
    gas: TxPriceNonceRef
    nonce: TxPriceItemRef

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(rq: TxPriceItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.itemList.len

proc `$`(rq: TxPriceNonceRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.nonceList.len


proc byInsertPrice(gp: var TxPriceItems; item: TxItemRef): TxPriceInx
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = gp.priceList.insert(item.tx.gasPrice)
    if rc.isOk:
      new result.gas
      result.gas.nonceList.init
      rc.value.data = result.gas
    else:
      result.gas = gp.priceList.eq(item.tx.gasPrice).value.data

  block:
    let rc = result.gas.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      new result.nonce
      result.nonce.itemList.init(1)
      rc.value.data = result.nonce
    else:
      result.nonce = result.gas.nonceList.eq(item.tx.nonce).value.data

proc byPrice(gp: var TxPriceItems; item: TxItemRef): Result[TxPriceInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var gasData: TxPriceNonceRef
  block:
    let rc = gp.priceList.eq(item.tx.gasPrice)
    if rc.isOk:
      gasData = rc.value.data
    else:
      return err()

  var nonceData: TxPriceItemRef
  block:
    let rc = gasData.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      nonceData = rc.value.data
    else:
      return err()

  ok(TxPriceInx(gas: gasData, nonce: nonceData))

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc txInit*(gp: var TxPriceItems) =
  gp.size = 0
  gp.priceList.init

proc txInsert*(gp: var TxPriceItems; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction item to the list. The function has no effect if the
  ## transaction exists, already.
  let gasRc = gp.byInsertPrice(item)
  if not gasRc.nonce.itemList.hasKey(item):
    discard gasRc.nonce.itemList.append(item,0)
    gp.size.inc
    gasRc.gas.size.inc

proc txDelete*(gp: var TxPriceItems; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove transaction from the list.
  let rc = gp.byPrice(item)
  if rc.isOK:
    rc.value.nonce.itemList.del(item)
    if rc.value.nonce.itemList.len == 0:
      discard  rc.value.gas.nonceList.delete(item.tx.nonce)
    if rc.value.gas.nonceList.len == 0:
      discard gp.priceList.delete(item.tx.gasPrice)
    else:
      rc.value.gas.size.dec
    gp.size.dec

proc txVerify*(gp: var TxPriceItems): Result[void,(TxPriceInfo,KeeQuInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## walk `GasInt` > `AccountNonce` > items
  let sRc = gp.priceList.verify
  if sRc.isErr:
    return err((txPriceVfyRbTree, keeQuOk))

  var
    allCount = 0
    rcGas = gp.priceList.ge(GasInt.low)
  while rcGas.isOk:
    var gasCount = 0
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    rcGas = gp.priceList.gt(gasKey)

    var rcNonce = gasData.nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
      rcNonce = gasData.nonceList.gt(nonceKey)

      allCount += nonceData.itemList.len
      gasCount += nonceData.itemList.len
      if nonceData.itemList.len == 0:
        return err((txPriceVfyLeafEmpty, keeQuOk))

      let rcItem = nonceData.itemList.verify
      if rcItem.isErr:
        return err((txPriceVfyLeafQueue, rcItem.error[2]))

    # end while
    if gasCount != gasData.size:
      return err((txPriceVfySize, keeQuOk))

  # end while
  if allCount != gp.size:
    return err((txPriceVfySize, keeQuOk))

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc nLeaves*(gp: var TxPriceItems): int {.inline.} =
  gp.size

proc len*(gp: var TxPriceItems): int {.inline.} =
  gp.priceList.len

# ------------------------------------------------------------------------------
# Public SLst ops -- `gasPrice` (level 0)
# ------------------------------------------------------------------------------

proc eq*(gp: var TxPriceItems; gasPrice: GasInt): auto {.inline.} =
  gp.priceList.eq(gasPrice)

proc ge*(gp: var TxPriceItems; gasPrice: GasInt): auto {.inline.} =
  gp.priceList.ge(gasPrice)

proc gt*(gp: var TxPriceItems; gasPrice: GasInt): auto {.inline.} =
  gp.priceList.gt(gasPrice)

proc le*(gp: var TxPriceItems; gasPrice: GasInt): auto {.inline.} =
  gp.priceList.le(gasPrice)

proc lt*(gp: var TxPriceItems; gasPrice: GasInt): auto {.inline.} =
  gp.priceList.lt(gasPrice)

# ------------------------------------------------------------------------------
# Public SLst ops -- nonce (level 1)
# ------------------------------------------------------------------------------

proc nLeaves*(nl: TxPriceNonceRef): int {.inline.} =
  nl.size

proc len*(nl: TxPriceNonceRef): int {.inline.} =
  nl.nonceList.len

proc eq*(nl: TxPriceNonceRef; nonce: AccountNonce): auto {.inline.} =
  nl.nonceList.eq(nonce)

proc ge*(nl: TxPriceNonceRef; nonce: AccountNonce): auto {.inline.} =
  nl.nonceList.ge(nonce)

proc gt*(nl: TxPriceNonceRef; nonce: AccountNonce): auto {.inline.} =
  nl.nonceList.gt(nonce)

proc le*(nl: TxPriceNonceRef; nonce: AccountNonce): auto {.inline.} =
  nl.nonceList.le(nonce)

proc lt*(nl: TxPriceNonceRef; nonce: AccountNonce): auto {.inline.} =
  nl.nonceList.lt(nonce)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
