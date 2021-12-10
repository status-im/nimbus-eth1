# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Table: `status` > `nonce`
## ==========================================
##

import
  ../../keequ,
  ../../slst,
  ../tx_info,
  ../tx_item,
  ./tx_leaf,
  eth/[common],
  stew/results

type
  TxStatusSchedRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` or `TxItemRef` insertion order
    size: int
    nonceList: Slst[AccountNonce,TxLeafItemRef]
    allList: TxLeafItemRef

  TxStatusTab* = object ##\
    ## Per status table
    size: int
    statusList: array[TxItemStatus,TxStatusSchedRef]

  TxStatusInx = object ##\
    ## Internal access data
    schedData: TxStatusSchedRef
    nonceData: TxLeafItemRef
    allData: TxLeafItemRef

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `$`(leaf: TxLeafItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $leaf.nItems

proc nActive(sq: TxStatusTab): int {.inline.} =
  ## Number of non-nil items
  for status in TxItemStatus:
    if not sq.statusList[status].isNil:
      result.inc


proc mkInxImpl(sq: var TxStatusTab; item: TxItemRef): TxStatusInx
    {.gcsafe,raises: [Defect,KeyError].} =
  block:
    result.schedData = sq.statusList[item.status]
    if result.schedData.isNil:
      new result.schedData
      result.schedData.nonceList.init
      sq.statusList[item.status] = result.schedData
  block:
    let rc = result.schedData.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      result.nonceData = txNew(type TxLeafItemRef)
      rc.value.data = result.nonceData
    else:
      result.nonceData = result.schedData.nonceList.eq(item.tx.nonce).value.data
  block:
    result.allData = result.schedData.allList
    if result.allData.isNil:
      result.allData = txNew(type TxLeafItemRef)
      result.schedData.allList = result.allData


proc getInxImpl(sq: var TxStatusTab; item: TxItemRef): Result[TxStatusInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxStatusInx

  block:
    inxData.schedData = sq.statusList[item.status]
    if inxData.schedData.isNil:
      return err()
  block:
    let rc = inxData.schedData.nonceList.eq(item.tx.nonce)
    if rc.isErr:
      return err()
    inxData.nonceData = rc.value.data
  block:
    inxData.allData = inxData.schedData.allList
    if inxData.allData.isNil:
      return err()

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(sq: var TxStatusTab; size = 10) =
  ## Optional constructor
  sq.size = 0
  sq.statusList.reset


proc txInsert*(sq: var TxStatusTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = sq.mkInxImpl(item)
  if inx.allData.txAppend(item):
    discard inx.nonceData.txAppend(item)
    sq.size.inc
    inx.schedData.size.inc


proc txDelete*(sq: var TxStatusTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = sq.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    sq.size.dec

    discard inx.allData.txDelete(item)
    if inx.allData.nItems == 0:
      sq.statusList[item.status] = nil
      return true

    inx.schedData.size.dec

    discard inx.nonceData.txDelete(item)
    if inx.nonceData.nItems == 0:
      discard inx.schedData.nonceList.delete(item.tx.nonce)

    return true


proc txVerify*(sq: var TxStatusTab): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## walk `IxItemStatus` > `AccountNonce` > items
  var totalCount = 0
  for status in TxItemStatus:
    var
      nonceCount = 0
      allCount = 0

    let schedData = sq.statusList[status]
    if not schedData.isNil:

      # ----- by nonce sub-list ---------------------------------

      block:
        let rc = schedData.nonceList.verify
        if rc.isErr:
          return err(txInfoVfyStatusRbTree)

      if schedData.nonceList.len == 0:
        return err(txInfoVfyStatusLeafEmpty)

      var rcNonce = schedData.nonceList.ge(AccountNonce.low)
      while rcNonce.isOk:
        let (nonceKey, itemData) = (rcNonce.value.key, rcNonce.value.data)
        rcNonce = schedData.nonceList.gt(nonceKey)

        block:
          let rc = itemData.txVerify
          if rc.isErr:
            return err(txInfoVfyStatusLeafQueue)

          if itemData.nItems == 0:
            return err(txInfoVfyStatusLeafEmpty)

        nonceCount += itemData.nItems

      # ----- all sub-list ---------------------------------

      block:
        let itemData = schedData.allList

        block:
          let rc = itemData.txVerify
          if rc.isErr:
            return err(txInfoVfyStatusLeafQueue)

          if itemData.nItems == 0:
            return err(txInfoVfyStatusLeafEmpty)

        allCount += itemData.nItems

      # ----- end sub-list ---------------------------------

      if schedData.size != nonceCount:
        return err(txInfoVfyStatusTotal)

      if schedData.size != allCount:
        return err(txInfoVfyStatusTotal)

      totalCount += schedData.size

  # end while
  if totalCount != sq.size:
    return err(txInfoVfyStatusTotal)

  ok()

# ------------------------------------------------------------------------------
# Public  array ops -- `TxItemStatus` (level 0)
# ------------------------------------------------------------------------------

proc len*(sq: var TxStatusTab): int {.inline.} =
  sq.nActive

proc nItems*(sq: var TxStatusTab): int {.inline.} =
  ## Getter, total number of items in the list
  sq.size

proc eq*(sq: var TxStatusTab; status: TxItemStatus):
       SLstResult[TxItemStatus,TxStatusSchedRef] {.inline.} =
  let schedData = sq.statusList[status]
  if schedData.isNil:
    return err(rbNotFound)
  toSLstResult(key = status, data = schedData)

# ------------------------------------------------------------------------------
# Public array ops -- `TxStatusSchedule` (level 1)
# ------------------------------------------------------------------------------

proc nItems*(schedData: TxStatusSchedRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  schedData.size

proc nItems*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc any*(schedData: TxStatusSchedRef):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  toSLstResult(key = AccountNonce.low, data = schedData.allList)

proc any*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.any
  err(rc.error)


proc eq*(schedData: TxStatusSchedRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  schedData.nonceList.eq(nonce)

proc eq*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(schedData: TxStatusSchedRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  schedData.nonceList.ge(nonce)

proc ge*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(schedData: TxStatusSchedRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  schedData.nonceList.gt(nonce)

proc gt*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(schedData: TxStatusSchedRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  schedData.nonceList.le(nonce)

proc le*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(schedData: TxStatusSchedRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  schedData.nonceList.lt(nonce)

proc lt*(rc: SLstResult[TxItemStatus,TxStatusSchedRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
