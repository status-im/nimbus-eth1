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
  ../../keequ,
  ../../slst,
  ../tx_info,
  ../tx_item,
  ./tx_leaf,
  eth/[common],
  stew/results

type
  TxSenderNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    size: int
    nonceList: Slst[AccountNonce,TxLeafItemRef]

  TxSenderSchedRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    size: int
    isLocalList: array[bool,TxSenderNonceRef]
    statusList: array[TxItemStatus,TxSenderNonceRef]
    allList: TxSenderNonceRef

  TxSenderTab* = object ##\
    ## Per address table
    size: int
    addrList: SLst[EthAddress,TxSenderSchedRef]

  TxSenderSchedule* = enum ##\
    ## Generalised key for sub-list to be used in `TxSenderNoncePair`
    txSenderLocal = 0   ## local sub-table
    txSenderRemote      ## remote sub-table
    txSenderAny         ## all entries
    txSenderQueued      ## by status ...
    txSenderPending
    txSenderStaged

  TxSenderInx = object ##\
    ## Internal access data
    sAddr: TxSenderSchedRef
    localNonce: TxSenderNonceRef   ## exclusive sub-table: local or remote
    localItem: TxLeafItemRef
    statusNonce: TxSenderNonceRef  ## by status items sub-list
    statusItem: TxLeafItemRef
    anyNonce: TxSenderNonceRef     ## all items sub-list
    anyItem: TxLeafItemRef


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

proc `$`(leaf: TxLeafItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $leaf.nItems

proc `$`(rq: TxSenderSchedRef): string =
  ## Needed by `rq.verify()` for printing error messages
  var n = 0
  if not rq.isLocalList[true].isNil: n.inc
  if not rq.isLocalList[false].isNil: n.inc
  $n


proc nActive(gs: TxSenderSchedRef): int {.inline.} =
  ## Number of non-nil items
  if not gs.isLocalList[true].isNil:
    result.inc
  if not gs.isLocalList[false].isNil:
    result.inc

proc cmp(a,b: EthAddress): int {.inline.} =
  ## mixin for SLst
  for n in 0 ..< EthAddress.len:
    if a[n] < b[n]:
      return -1
    if b[n] < a[n]:
      return 1


proc toSenderSchedule(local: bool): TxSenderSchedule {.inline.} =
  ## For query functions, eq()
  if local: txSenderLocal else: txSenderLocal

proc toSenderSchedule(status: TxItemStatus): TxSenderSchedule {.inline.} =
  case status
  of txItemQueued:
    return txSenderQueued
  of txItemPending:
    return txSenderPending
  of txItemStaged:
    return txSenderStaged


proc mkItemInx(sub: var TxSenderNonceRef; item: TxItemRef): TxLeafItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = sub.nonceList.insert(item.tx.nonce)
  if rc.isErr:
    return sub.nonceList.eq(item.tx.nonce).value.data
  result = txNew(type TxLeafItemRef)
  rc.value.data = result


proc mkInxImpl(gt: var TxSenderTab; item: TxItemRef): TxSenderInx
    {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = gt.addrList.insert(item.sender)
    if rc.isOk:
      new result.sAddr
      rc.value.data = result.sAddr
    else:
      result.sAddr = gt.addrList.eq(item.sender).value.data

  # by local/remote items sub-list
  block:
    if result.sAddr.isLocalList[item.local].isNil:
      new result.localNonce
      result.localNonce.nonceList.init
      result.sAddr.isLocalList[item.local] = result.localNonce
    else:
      result.localNonce = result.sAddr.isLocalList[item.local]
    result.localItem = result.localNonce.mkItemInx(item)

  # by status items sub-list
  block:
    if result.sAddr.statusList[item.status].isNil:
      new result.statusNonce
      result.statusNonce.nonceList.init
      result.sAddr.statusList[item.status] = result.statusNonce
    else:
      result.statusNonce = result.sAddr.statusList[item.status]
    result.statusItem = result.statusNonce.mkItemInx(item)

  # all items sub-list
  block:
    if result.sAddr.allList.isNil:
      new result.anyNonce
      result.anyNonce.nonceList.init
      result.sAddr.allList = result.anyNonce
    else:
      result.anyNonce = result.sAddr.allList
    result.anyItem = result.anyNonce.mkItemInx(item)


proc getInxImpl(gt: var TxSenderTab; item: TxItemRef): Result[TxSenderInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxSenderInx

  block:
    let rc = gt.addrList.eq(item.sender)
    if rc.isOk:
      inxData.sAddr = rc.value.data
    else:
      return err()

  # by local/remote items sub-list
  block:
    inxData.localNonce = inxData.sAddr.isLocalList[item.local]
    if inxData.localNonce.isNil:
      return err()
    let rc = inxData.localNonce.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      inxData.localItem = rc.value.data
    else:
      return err()

  # by status items sub-list
  block:
    inxData.statusNonce = inxData.sAddr.statusList[item.status]
    if inxData.localNonce.isNil:
      return err()
    let rc = inxData.statusNonce.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      inxData.statusItem = rc.value.data
    else:
      return err()

  # all items sub-list
  block:
    inxData.anyNonce = inxData.sAddr.allList
    inxData.anyItem = inxData.anyNonce.nonceList.eq(item.tx.nonce).value.data

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(gt: var TxSenderTab) =
  ## Constructor
  gt.size = 0
  gt.addrList.init


proc txInsert*(gt: var TxSenderTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = gt.mkInxImpl(item)
  if inx.anyItem.txAppend(item):
    discard inx.localItem.txAppend(item)
    discard inx.statusItem.txAppend(item)
    gt.size.inc
    inx.sAddr.size.inc
    inx.localNonce.size.inc
    inx.statusNonce.size.inc
    inx.anyNonce.size.inc


proc txDelete*(gt: var TxSenderTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = gt.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    gt.size.dec
    inx.sAddr.size.dec

    discard inx.anyItem.txDelete(item)
    if inx.anyItem.nItems == 0:
      discard inx.anyNonce.nonceList.delete(item.tx.nonce)
      if inx.anyNonce.nonceList.len == 0:
        discard gt.addrList.delete(item.sender)
        return true

    inx.localNonce.size.dec
    inx.statusNonce.size.dec
    inx.anyNonce.size.dec

    discard inx.localItem.txDelete(item)
    if inx.localItem.nItems == 0:
      discard inx.localNonce.nonceList.delete(item.tx.nonce)
      if inx.localNonce.nonceList.len == 0:
        inx.sAddr.isLocalList[item.local] = nil

    discard inx.statusItem.txDelete(item)
    if inx.statusItem.nItems == 0:
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

    # at lest ((local or remote) and merged) lists must be available
    if schedData.nActive == 0:
      return err(txInfoVfySenderLeafEmpty)
    if schedData.allList.isNil:
      return err(txInfoVfySenderLeafEmpty)

    # local/remote list
    # ----------------------------------------------------------------
    var localCount = 0
    for local in [true, false]:
      let localData = schedData.isLocalList[local]

      if not localData.isNil:
        block:
          let rc = localData.nonceList.verify
          if rc.isErr:
            return err(txInfoVfySenderRbTree)

        var subCount = 0
        var rcNonce = localData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, itemData) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = localData.nonceList.gt(nonceKey)

          subCount += itemData.nItems

          if itemData.nItems == 0:
            return err(txInfoVfySenderLeafEmpty)

          let rcItem = itemData.txVerify
          if rcItem.isErr:
            return err(txInfoVfySenderLeafQueue)

        # end while
        if subCount != localData.size:
          return err(txInfoVfySenderTotal)

        localCount += subCount

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

        var subCount = 0
        var rcNonce = statusData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, itemData) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = statusData.nonceList.gt(nonceKey)

          subCount += itemData.nItems

          if itemData.nItems == 0:
            return err(txInfoVfySenderLeafEmpty)

          let rcItem = itemData.txVerify
          if rcItem.isErr:
            return err(txInfoVfySenderLeafQueue)

        # end while
        if subCount != statusData.size:
          return err(txInfoVfySenderTotal)

        statusCount += subCount

    # allList
    # ----------------------------------------------------------------
    var allCount = 0
    block:
      let rc = schedData.allList.nonceList.verify
      if rc.isErr:
        return err(txInfoVfySenderRbTree)

      var rcNonce =  schedData.allList.nonceList.ge(AccountNonce.low)
      while rcNonce.isOk:
        let (nonceKey, itemData) = (rcNonce.value.key, rcNonce.value.data)
        rcNonce =  schedData.allList.nonceList.gt(nonceKey)

        allCount += itemData.nItems

        if itemData.nItems == 0:
          return err(txInfoVfySenderLeafEmpty)

        let rcItem = itemData.txVerify
        if rcItem.isErr:
          return err(txInfoVfySenderLeafQueue)

      # end while
      if allCount != schedData.allList.size:
        return err(txInfoVfySenderTotal)

    # end for
    if localCount != schedData.size:
      return err(txInfoVfySenderTotal)
    if statusCount != schedData.size:
      return err(txInfoVfySenderTotal)
    if allCount != schedData.size:
      return err(txInfoVfySenderTotal)

    totalCount += localCount

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
# Public array ops -- `TxSenderLocus` or any (level 1)
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


proc eq*(schedData: TxSenderSchedRef; local: bool):
       SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Return local, or remote entries sub-lists
  let nonceData = schedData.isLocalList[local]
  if nonceData.isNil:
    return err(rbNotFound)
  toSLstResult(key = local.toSenderSchedule, data = nonceData)

proc eq*(rc: SLstResult[EthAddress,TxSenderSchedRef]; local: bool):
       SLstResult[TxSenderSchedule,TxSenderNonceRef] {.inline.} =
  ## Return local, or remote entries sub-list
  if rc.isOK:
    return rc.value.data.eq(local)
  err(rc.error)


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
  of txSenderLocal, txSenderRemote:
    return schedData.eq(key == txSenderLocal)
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
  nonceData.size

proc nItems*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef]):
           int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.le(nonce)

proc le*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: SLstResult[TxSenderSchedule,TxSenderNonceRef];
         nonce: AccountNonce):
           SLstResult[AccountNonce,TxLeafItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
