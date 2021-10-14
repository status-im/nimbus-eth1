# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Table: `Sender` > `local/remote | status | all` > `nonce`
## ==========================================================================
##

import
  ../../slst,
  ../tx_info,
  ../tx_item,
  eth/[common],
  stew/results

type
  TxSenderNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    nonceList: Slst[AccountNonce,TxItemRef]

  TxSenderSchedRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    size: int
    statusList: array[TxItemStatus,TxSenderNonceRef]
    allList: TxSenderNonceRef

  TxSenderTab* = object ##\
    ## Per address table
    size: int
    addrList: SLst[EthAddress,TxSenderSchedRef]

  TxSenderSchedule* = enum ##\
    ## Generalised key for sub-list to be used in `TxSenderNoncePair`
    txSenderAny = 0     ## all entries
    txSenderQueued      ## by status ...
    txSenderPending
    txSenderStaged

  TxSenderInx = object ##\
    ## Internal access data
    sAddr: TxSenderSchedRef
    statusNonce: TxSenderNonceRef  ## by status items sub-list
    anyNonce: TxSenderNonceRef     ## all items sub-list

const
  minEthAddress = block:
    var rc: EthAddress
    rc

  maxEthAddress = block:
    var rc: EthAddress
    for n in 0 ..< rc.len:
      rc[n] = 255
    rc

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `$`(rq: TxSenderSchedRef): string =
  ## Needed by `rq.verify()` for printing error messages
  var n = 0
  for status in TxItemStatus:
    if not rq.statusList[status].isNil:
      n.inc
  $n

proc nActive(rq: TxSenderSchedRef): int {.inline.} =
  ## Number of non-nil items
  for status in TxItemStatus:
    if not rq.statusList[status].isNil:
      result.inc

proc cmp(a,b: EthAddress): int {.inline.} =
  ## mixin for SLst
  for n in 0 ..< EthAddress.len:
    if a[n] < b[n]:
      return -1
    if b[n] < a[n]:
      return 1

proc toSenderSchedule(status: TxItemStatus): TxSenderSchedule {.inline.} =
  case status
  of txItemQueued:
    return txSenderQueued
  of txItemPending:
    return txSenderPending
  of txItemStaged:
    return txSenderStaged


proc mkInxImpl(gt: var TxSenderTab; item: TxItemRef): Result[TxSenderInx,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxSenderInx
  block:
    let rc = gt.addrList.insert(item.sender)
    if rc.isOk:
      new inxData.sAddr
      rc.value.data = inxData.sAddr
    else:
      inxData.sAddr = gt.addrList.eq(item.sender).value.data

  # all items sub-list
  if inxData.sAddr.allList.isNil:
    new inxData.anyNonce
    inxData.anyNonce.nonceList.init
    inxData.sAddr.allList = inxData.anyNonce
  else:
    inxData.anyNonce = inxData.sAddr.allList
  block:
    let rc = inxData.anyNonce.nonceList.insert(item.tx.nonce)
    if rc.isErr:
      return err()
    rc.value.data = item

  # by status items sub-list
  if inxData.sAddr.statusList[item.status].isNil:
    new inxData.statusNonce
    inxData.statusNonce.nonceList.init
    inxData.sAddr.statusList[item.status] = inxData.statusNonce
  else:
    inxData.statusNonce = inxData.sAddr.statusList[item.status]
  # this is a new item, checked at `all items sub-list` above
  inxData.statusNonce.nonceList.insert(item.tx.nonce).value.data = item

  return ok(inxData)


proc getInxImpl(gt: var TxSenderTab; item: TxItemRef): Result[TxSenderInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =

  var inxData: TxSenderInx
  let rc = gt.addrList.eq(item.sender)
  if rc.isErr:
    return err()

  # Sub-lists are non-nil as `TxSenderSchedRef` cannot be empty
  inxData.sAddr = rc.value.data

  # by status items sub-list
  inxData.statusNonce = inxData.sAddr.statusList[item.status]

  # all items sub-list
  inxData.anyNonce = inxData.sAddr.allList

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(gt: var TxSenderTab) =
  ## Constructor
  gt.size = 0
  gt.addrList.init


proc txInsert*(gt: var TxSenderTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let rc = gt.mkInxImpl(item)
  if rc.isOK:
    let inx = rc.value
    gt.size.inc
    inx.sAddr.size.inc
    return true


proc txDelete*(gt: var TxSenderTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = gt.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    gt.size.dec
    inx.sAddr.size.dec

    discard inx.anyNonce.nonceList.delete(item.tx.nonce)
    if inx.anyNonce.nonceList.len == 0:
      # this was the last nonce for that sender account
      discard gt.addrList.delete(item.sender)
      return true

    discard inx.statusNonce.nonceList.delete(item.tx.nonce)
    if inx.statusNonce.nonceList.len == 0:
      inx.sAddr.statusList[item.status] = nil

    return true


proc txVerify*(gt: var TxSenderTab): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Walk `EthAddress` > `TxSenderLocus` > `AccountNonce` > items
  block:
    let rc = gt.addrList.verify
    if rc.isErr:
      return err(txInfoVfySenderRbTree)
  var
    totalCount = 0
    rcAddr = gt.addrList.ge(minEthAddress)
  while rcAddr.isOk:
    var addrCount = 0
    let (addrKey, schedData) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = gt.addrList.gt(addrKey)

    # at least one of status lists must be available
    if schedData.nActive == 0:
      return err(txInfoVfySenderLeafEmpty)
    if schedData.allList.isNil:
      return err(txInfoVfySenderLeafEmpty)

    # status list
    # ----------------------------------------------------------------
    var statusCount = 0
    for status in TxItemStatus:
      let statusData = schedData.statusList[status]

      if not statusData.isNil:
        block:
          let rc = statusData.nonceList.verify
          if rc.isErr:
            return err(txInfoVfySenderRbTree)

        statusCount += statusData.nonceList.len

    # allList
    # ----------------------------------------------------------------
    var allCount = 0
    block:
      var allData = schedData.allList

      block:
        let rc = allData.nonceList.verify
        if rc.isErr:
          return err(txInfoVfySenderRbTree)

      allCount = allData.nonceList.len

    # end for
    if statusCount != schedData.size:
      return err(txInfoVfySenderTotal)
    if allCount != schedData.size:
      return err(txInfoVfySenderTotal)

    totalCount += allCount

  # end while
  if totalCount != gt.size:
    return err(txInfoVfySenderTotal)

  ok()

# ------------------------------------------------------------------------------
# Public SLst ops -- `EthAddress` (level 0)
# ------------------------------------------------------------------------------

proc len*(gt: var TxSenderTab): int {.inline.} =
  gt.addrList.len

proc nItems*(gt: var TxSenderTab): int {.inline.} =
  ## Getter, total number of items in the list
  gt.size

proc eq*(gt: var TxSenderTab; sender: EthAddress):
       SLstResult[EthAddress,TxSenderSchedRef] {.inline.} =
  gt.addrList.eq(sender)

proc first*(gt: var TxSenderTab):
          SLstResult[EthAddress,TxSenderSchedRef] {.inline.} =
  gt.addrList.ge(minEthAddress)

proc last*(gt: var TxSenderTab):
          SLstResult[EthAddress,TxSenderSchedRef] {.inline.} =
  gt.addrList.le(maxEthAddress)

proc next*(gt: var TxSenderTab; key: EthAddress):
          SLstResult[EthAddress,TxSenderSchedRef] {.inline.} =
  gt.addrList.gt(key)

proc prev*(gt: var TxSenderTab; key: EthAddress):
          SLstResult[EthAddress,TxSenderSchedRef] {.inline.} =
  gt.addrList.lt(key)

# ------------------------------------------------------------------------------
# Public array ops -- `TxSenderSchedule` (level 1)
# ------------------------------------------------------------------------------

proc len*(schedData: TxSenderSchedRef): int {.inline.} =
  schedData.nActive


proc nItems*(schedData: TxSenderSchedRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  schedData.size

proc nItems*(rc: SLstResult[EthAddress,TxSenderSchedRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(schedData: TxSenderSchedRef; status: TxItemStatus):
       SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Return by status sub-list
  let nonceData = schedData.statusList[status]
  if nonceData.isNil:
    return err(rbNotFound)
  toSLstResult(key = status.toSenderSchedule, data = nonceData)

proc eq*(rc: SLstResult[EthAddress,TxSenderSchedRef]; status: TxItemStatus):
       SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Return by status sub-list
  if rc.isOK:
    return rc.value.data.eq(status)
  err(rc.error)


proc any*(schedData: TxSenderSchedRef):
        SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Return all-entries sub-list
  let nonceData = schedData.allList
  if nonceData.isNil:
    return err(rbNotFound)
  toSLstResult(key = txSenderAny, data = nonceData)

proc any*(rc: SLstResult[EthAddress,TxSenderSchedRef]):
        SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Return all-entries sub-list
  if rc.isOK:
    return rc.value.data.any
  err(rc.error)


proc eq*(schedData: TxSenderSchedRef;
         key: TxSenderSchedule):
           SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Variant of `eq()` using unified key schedule
  case key
  of txSenderAny:
    return schedData.any
  of txSenderQueued:
    return schedData.eq(txItemQueued)
  of txSenderPending:
    return schedData.eq(txItemPending)
  of txSenderStaged:
    return schedData.eq(txItemStaged)

proc eq*(rc: SLstResult[EthAddress,TxSenderSchedRef];
         key: TxSenderSchedule):
           SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(key)
  err(rc.error)

# ------------------------------------------------------------------------------
# Public SLst ops -- `AccountNonce` (level 2)
# ------------------------------------------------------------------------------

proc len*(nonceData: TxSenderNonceRef): int {.inline.} =
  let rc = nonceData.nonceList.len


proc nItems*(nonceData: TxSenderNonceRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  nonceData.nonceList.len

proc nItems*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef]):
           int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.le(nonce)

proc le*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxItemRef] {.inline.} =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
