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
  ../../keequ,
  ../../slst,
  ../tx_info,
  ../tx_item,
  ./tx_leaf,
  eth/common,
  stew/results

type
  TxPriceItemMap* = ##\
    ## Process item before storing. This function may modify the contents
    ## of the `item` argument
    proc(item: TxItemRef) {.gcsafe,raises: [Defect].}

  TxPriceNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    size: int
    nonceList: Slst[AccountNonce,TxLeafItemRef]

  TxPriceTab* = object ##\
    ## Item list indexed by `GasInt` > `AccountNonce`
    size: int                     ## Total number of leaves
    update: TxPriceItemMap        ## e.g. for applying `baseFee` before insert
    priceList: SLst[GasPriceEx,TxPriceNonceRef]

  TxPriceInx = object ##\
    ## Internal access data
    gas: TxPriceNonceRef
    nonce: TxLeafItemRef

let
  txPriceItemMapPass*: TxPriceItemMap = ##\
    ## Ident function
    proc(item: TxItemRef) = discard

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(rq: TxPriceNonceRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.nonceList.len


proc mkInxImpl(gp: var TxPriceTab; item: TxItemRef): TxPriceInx
    {.gcsafe,raises: [Defect,KeyError].} =
  # start with updating argument `item` (typically setting base fee)
  gp.update(item)
  block:
    let rc = gp.priceList.insert(item.effGasTip)
    if rc.isOk:
      new result.gas
      result.gas.nonceList.init
      rc.value.data = result.gas
    else:
      result.gas = gp.priceList.eq(item.effGasTip).value.data
  block:
    let rc = result.gas.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      result.nonce = txNew(type TxLeafItemRef)
      rc.value.data = result.nonce
    else:
      result.nonce = result.gas.nonceList.eq(item.tx.nonce).value.data


proc getInxImpl(gp: var TxPriceTab; item: TxItemRef): Result[TxPriceInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxPriceInx
  block:
    let rc = gp.priceList.eq(item.effGasTip)
    if rc.isOk:
      inxData.gas = rc.value.data
    else:
      return err()
  block:
    let rc = inxData.gas.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      inxData.nonce = rc.value.data
    else:
      return err()

  ok(inxData)

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc txInit*(gp: var TxPriceTab; update = txPriceItemMapPass) =
  gp.size = 0
  gp.priceList.init
  gp.update = update


proc txInsert*(gp: var TxPriceTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction item to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = gp.mkInxImpl(item)
  if inx.nonce.txAppend(item):
    gp.size.inc
    inx.gas.size.inc


proc txDelete*(gp: var TxPriceTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove transaction from the list.
  let rc = gp.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    discard inx.nonce.txDelete(item)
    gp.size.dec
    inx.gas.size.dec

    if inx.nonce.nItems == 0:
      discard inx.gas.nonceList.delete(item.tx.nonce)
      if inx.gas.nonceList.len == 0:
        discard gp.priceList.delete(item.effGasTip)


proc txReorg(gp: var TxPriceTab) {.gcsafe,raises: [Defect,KeyError].} =
  ## reorg => rebuild list
  var
    stale = gp.priceList.move         # `priceList` becomes empty
    rcGas = stale.ge(GasPriceEx.low)  # all data in `stale`

  gp.size = 0                         # correct for empty `priceList`

  while rcGas.isOk:
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    rcGas = stale.gt(gasKey)

    var rcNonce = gasData.nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
      rcNonce = gasData.nonceList.gt(nonceKey)

      var rcItem = nonceData.first
      while rcItem.isOK:
        let item = rcItem.value
        rcItem = nonceData.next(item)
        gp.txInsert(item) # re-insert into new list


proc txVerify*(gp: var TxPriceTab): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## walk `GasPriceEx` > `AccountNonce` > items
  var allCount = 0

  block:
    let rc = gp.priceList.verify
    if rc.isErr:
      return err(txInfoVfyGasTipList)

  var rcGas = gp.priceList.ge(GasPriceEx.low)
  while rcGas.isOk:
    var gasCount = 0
    let (gasKey, gasData) = (rcGas.value.key, rcGas.value.data)
    rcGas = gp.priceList.gt(gasKey)

    var rcNonce = gasData.nonceList.ge(AccountNonce.low)
    while rcNonce.isOk:
      let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
      rcNonce = gasData.nonceList.gt(nonceKey)

      allCount += nonceData.nItems
      gasCount += nonceData.nItems
      if nonceData.nItems == 0:
        return err(txInfoVfyGasTipLeafEmpty)

      let rcItem = nonceData.txVerify
      if rcItem.isErr:
        return err(txInfoVfyGasTipLeafQueue)

    # end while
    if gasCount != gasData.size:
      return err(txInfoVfyGasTipTotal)

  # end while
  if allCount != gp.size:
    return err(txInfoVfyGasTipTotal)

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------
#[
# core/types/tx_list.go(442): .. func (h *priceHeap) cmp(a, b ..
proc cmp*(gp: var TxPriceTab; a, b: TxItemRef): int =
  if gp.baseFeeEnabled:
    # Compare effective tips if `baseFee` is specified
    let cmpEffGasTips = a.effectiveGasTip.cmp(b.effectiveGasTip)
    if cmpEffGasTips != 0:
      return cmpEffGasTips

  # Compare fee caps if `baseFee` is not specified or effective tips are equal
  let cmpGasFeeCaps = a.tx.gasFeeCap.cmp(b.tx.gasFeeCap)
  if cmpGasFeeCaps != 0:
    return

  # Compare tips if effective tips and fee caps are equal
  a.tx.gasTipCap.cmp(b.tx.gasTipCap)
]#
# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc update*(gp: var TxPriceTab): TxPriceItemMap {.inline.} =
  ## Getter, returns update function, e.g. for adjusting  base fee
  return gp.update

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `update=`*(gp: var TxPriceTab; val: TxPriceItemMap)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Setter, may re-calculate base fee (implies reorg).
  gp.update = val
  gp.txReorg

# ------------------------------------------------------------------------------
# Public SLst ops -- `effectiveGasTip` (level 0)
# ------------------------------------------------------------------------------

proc nItems*(gp: var TxPriceTab): int {.inline.} =
  ## Getter, total number of items in the list
  gp.size

proc len*(gp: var TxPriceTab): int {.inline.} =
  ## Getter, number of different price values in the list
  gp.priceList.len

proc eq*(gp: var TxPriceTab; effectiveGasTip: GasPriceEx):
       SLstResult[GasPriceEx,TxPriceNonceRef] {.inline.} =
  gp.priceList.eq(effectiveGasTip)

proc ge*(gp: var TxPriceTab; effectiveGasTip: GasPriceEx):
       SLstResult[GasPriceEx,TxPriceNonceRef] {.inline.} =
  gp.priceList.ge(effectiveGasTip)

proc gt*(gp: var TxPriceTab; effectiveGasTip: GasPriceEx):
       SLstResult[GasPriceEx,TxPriceNonceRef] {.inline.} =
  gp.priceList.gt(effectiveGasTip)

proc le*(gp: var TxPriceTab; effectiveGasTip: GasPriceEx):
       SLstResult[GasPriceEx,TxPriceNonceRef] {.inline.} =
  gp.priceList.le(effectiveGasTip)

proc lt*(gp: var TxPriceTab; effectiveGasTip: GasPriceEx):
       SLstResult[GasPriceEx,TxPriceNonceRef] {.inline.} =
  gp.priceList.lt(effectiveGasTip)

# ------------------------------------------------------------------------------
# Public SLst ops -- nonce (level 1)
# ------------------------------------------------------------------------------

proc len*(nonceData: TxPriceNonceRef): int {.inline.} =
  nonceData.nonceList.len


proc nItems*(nonceData: TxPriceNonceRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  nonceData.size

proc nItems*(rc: SLstResult[GasPriceEx,TxPriceNonceRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(nonceData: TxPriceNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: SLstResult[GasPriceEx,TxPriceNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.nonceList.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxPriceNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: SLstResult[GasPriceEx,TxPriceNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.nonceList.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxPriceNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: SLstResult[GasPriceEx,TxPriceNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.nonceList.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxPriceNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.le(nonce)

proc le*(rc: SLstResult[GasPriceEx,TxPriceNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.nonceList.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxPriceNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: SLstResult[GasPriceEx,TxPriceNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.nonceList.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
