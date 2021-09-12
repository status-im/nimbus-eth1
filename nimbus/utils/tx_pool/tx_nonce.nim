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
  TxNonceInfo* = enum
    txNonceOk = 0
    txNonceVfyRbTree    ## Corrupted RB tree
    txNonceVfyLeafEmpty ## Empty leaf list
    txNonceVfyLeafQueue ## Corrupted leaf list
    txNonceVfySize      ## Size count mismatch

  TxNonceMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxNonceItemRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    itemList*: KeeQu[TxItemRef,TxNonceMark]

  TxNoncePriceRef* = ref object ##\
    ## Sub-list ordered by `GasInt` values containing nonce lists. These
    ## item lists.
    size: int
    priceList*: SLst[GasInt,TxNonceItemRef]

  TxNonceItems* = object ##\
    ## Item list indexed by `AccountNonce` > `GasPrice`.
    size: int
    nonceList: SLst[AccountNonce,TxNoncePriceRef] ##\

  TxNonceInx = object ##\
    ## Internal access data
    nonce: TxNoncePriceRef
    gas: TxNonceItemRef

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(rq: TxNonceItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.itemList.len

proc `$`(rq: TxNoncePriceRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.priceList.len


proc byInsertNonce(gp: var TxNonceItems; item: TxItemRef): TxNonceInx
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = gp.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      new result.nonce
      result.nonce.priceList.init
      rc.value.data = result.nonce
    else:
      result.nonce = gp.nonceList.eq(item.tx.nonce).value.data
  block:
    let rc = result.nonce.priceList.insert(item.tx.gasPrice)
    if rc.isOk:
      new result.gas
      result.gas.itemList.init(1)
      rc.value.data = result.gas
    else:
      result.gas = result.nonce.priceList.eq(item.tx.gasPrice).value.data

proc byNonce(gp: var TxNonceItems; item: TxItemRef): Result[TxNonceInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var nonceData: TxNoncePriceRef
  block:
    let rc = gp.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      nonceData = rc.value.data
    else:
      return err()

  var gasData: TxNonceItemRef
  block:
    let rc = nonceData.priceList.eq(item.tx.gasPrice)
    if rc.isOk:
      gasData = rc.value.data
    else:
      return err()

  ok(TxNonceInx(gas: gasData, nonce: nonceData))

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc txInit*(gp: var TxNonceItems) =
  gp.size = 0
  gp.nonceList.init

proc txInsert*(gp: var TxNonceItems; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction item to the list. The function has no effect if the
  ## transaction exists, already.
  let nonceRc = gp.byInsertNonce(item)
  if not nonceRc.gas.itemList.hasKey(item):
    discard nonceRc.gas.itemList.append(item,0)
    gp.size.inc
    nonceRc.nonce.size.inc

proc txDelete*(gp: var TxNonceItems; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove transaction from the list.
  let rc = gp.byNonce(item)
  if rc.isOK:
    rc.value.gas.itemList.del(item)
    if rc.value.gas.itemList.len == 0:
      discard rc.value.nonce.priceList.delete(item.tx.gasPrice)
    if rc.value.nonce.priceList.len == 0:
      discard gp.nonceList.delete(item.tx.nonce)
    else:
      rc.value.nonce.size.dec
    gp.size.dec

proc txVerify*(gp: var TxNonceItems): Result[void,(TxNonceInfo,KeeQuInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## walk `AccountNonce` > `GasInt` > items
  let sRc = gp.nonceList.verify
  if sRc.isErr:
    return err((txNonceVfyRbTree, keeQuOk))

  var
    allCount = 0
    rcNonce = gp.nonceList.ge(AccountNonce.low)
  while rcNonce.isOk:
    var nonceCount = 0
    let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
    rcNonce = gp.nonceList.gt(nonceKey)

    var rcGas = nonceData.priceList.ge(GasInt.low)
    while rcGas.isOk:
      let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
      rcGas = nonceData.priceList.gt(gasKey)

      allCount += gasData.itemList.len
      nonceCount += gasData.itemList.len
      if gasData.itemList.len == 0:
        return err((txNonceVfyLeafEmpty, keeQuOk))

      let rcItem = gasData.itemList.verify
      if rcItem.isErr:
        return err((txNonceVfyLeafQueue, rcItem.error[2]))

    # end while
    if nonceCount != nonceData.size:
      return err((txNonceVfySize, keeQuOk))

  # end while
  if allCount != gp.size:
    return err((txNonceVfySize, keeQuOk))

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc nLeaves*(gp: var TxNonceItems): int {.inline.} =
  gp.size

proc len*(gp: var TxNonceItems): int {.inline.} =
  gp.nonceList.len

# ------------------------------------------------------------------------------
# Public SLst ops -- `nonce` (level 0)
# ------------------------------------------------------------------------------

proc eq*(gp: var TxNonceItems; nonce: AccountNonce): auto {.inline.} =
  gp.nonceList.eq(nonce)

proc ge*(gp: var TxNonceItems; nonce: AccountNonce): auto {.inline.} =
  gp.nonceList.ge(nonce)

proc gt*(gp: var TxNonceItems; nonce: AccountNonce): auto {.inline.} =
  gp.nonceList.gt(nonce)

proc le*(gp: var TxNonceItems; nonce: AccountNonce): auto {.inline.} =
  gp.nonceList.le(nonce)

proc lt*(gp: var TxNonceItems; nonce: AccountNonce): auto {.inline.} =
  gp.nonceList.lt(nonce)

# ------------------------------------------------------------------------------
# Public SLst ops -- nonce (level 1)
# ------------------------------------------------------------------------------

proc nLeaves*(pl: TxNoncePriceRef): int {.inline.} =
  pl.size

proc len*(pl: TxNoncePriceRef): int {.inline.} =
  pl.priceList.len

proc eq*(pl: TxNoncePriceRef; gasPrice: GasInt): auto {.inline.} =
  pl.priceList.eq(gasPrice)

proc ge*(pl: TxNoncePriceRef; gasPrice: GasInt): auto {.inline.} =
  pl.priceList.ge(gasPrice)

proc gt*(pl: TxNoncePriceRef; gasPrice: GasInt): auto {.inline.} =
  pl.priceList.gt(gasPrice)

proc le*(pl: TxNoncePriceRef; gasPrice: GasInt): auto {.inline.} =
  pl.priceList.le(gasPrice)

proc lt*(pl: TxNoncePriceRef; gasPrice: GasInt): auto {.inline.} =
  pl.priceList.lt(gasPrice)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
