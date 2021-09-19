# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Sender Group Table
## ===================================
##

import
  ../../keequ,
  ../../slst,
  ../tx_item,
  eth/[common],
  stew/results

type
  TxSenderInfo* = enum
    txSenderOk = 0
    txSenderVfyRbTree    ## Corrupted RB tree
    txSenderVfyLeafEmpty ## Empty leaf list
    txSenderVfyLeafQueue ## Corrupted leaf list
    txSenderVfySize      ## Size count mismatch

  TxSenderSchedule = enum ##\
    ## Sub-queues
    txSenderLocal = 0   ## local sub-table
    txSenderRemote = 1  ## remote sub-table
    txSenderAny = 2     ## merged table: local + remote

  TxSenderItemRef* = ref object ##\
    ## All transaction items accessed by the same index are chronologically
    ## queued.
    itemList: KeeQuNV[TxItemRef]

  TxSenderNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    size: int
    nonceList: Slst[AccountNonce,TxSenderItemRef]

  TxSenderSchedRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    size: int
    schedList: array[TxSenderSchedule,TxSenderNonceRef]

  TxSenderTab* = object ##\
    ## Per address table
    size: int
    addrList: SLst[EthAddress,TxSenderSchedRef]

  TxSenderNoncePair* = object ##\
    ## Intermediate result, somehow similar to
    ## `SLstResult[bool,TxSenderNonceRef]` (only that the `key` field is
    ## read-only there)
    key*: TxSenderSchedule
    data*: TxSenderNonceRef

  TxSenderInx = object ##\
    ## Internal access data
    sAddr: TxSenderSchedRef
    lrSched: TxSenderNonceRef ## exclusive sub-table: local or remote
    lrNonce: TxSenderItemRef  ## exclusive sub-table: local or remote
    xSched: TxSenderNonceRef  ## merged sub-table: local + remote
    xNonce: TxSenderItemRef   ## merged sub-table: local + remote

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

proc nActive(gs: TxSenderSchedRef): int {.inline.} =
  ## Number of non-nil items
  if not gs.schedList[txSenderLocal].isNil:
    result.inc
  if not gs.schedList[txSenderRemote].isNil:
    result.inc

proc `$`(rq: TxSenderItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.itemList.len

proc `$`(rq: TxSenderSchedRef): string =
  ## Needed by `rq.verify()` for printing error messages
  var n = 0
  if not rq.schedList[txSenderLocal].isNil: n.inc
  if not rq.schedList[txSenderRemote].isNil: n.inc
  $n

proc cmp(a,b: EthAddress): int {.inline.} =
  ## mixin for SLst
  for n in 0 ..< EthAddress.len:
    if a[n] < b[n]:
      return -1
    if b[n] < a[n]:
      return 1

proc `not`(sched: TxSenderSchedule): TxSenderSchedule {.inline.} =
  if sched == txSenderLocal: txSenderRemote else: txSenderLocal

proc toSenderLR*(local: bool): TxSenderSchedule {.inline.} =
  if local: txSenderLocal else: txSenderRemote


proc mkInxImpl(gt: var TxSenderTab; item: TxItemRef): TxSenderInx
    {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = gt.addrList.insert(item.sender)
    if rc.isOk:
      new result.sAddr
      rc.value.data = result.sAddr
    else:
      result.sAddr = gt.addrList.eq(item.sender).value.data
  # exclusive sub-tables
  block:
    let sched = item.local.toSenderLR
    if result.sAddr.schedList[sched].isNil:
      new result.lrSched
      result.lrSched.nonceList.init
      result.sAddr.schedList[sched] = result.lrSched
    else:
      result.lrSched = result.sAddr.schedList[sched]
  block:
    let rc = result.lrSched.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      new result.lrNonce
      result.lrNonce.itemList.init(1)
      rc.value.data = result.lrNonce
    else:
      result.lrNonce = result.lrSched.nonceList.eq(item.tx.nonce).value.data
  # merged sub-table
  block:
    if result.sAddr.schedList[txSenderAny].isNil:
      new result.xSched
      result.xSched.nonceList.init
      result.sAddr.schedList[txSenderAny] = result.xSched
    else:
      result.xSched = result.sAddr.schedList[txSenderAny]
  block:
    let rc = result.xSched.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      new result.xNonce
      result.xNonce.itemList.init(1)
      rc.value.data = result.xNonce
    else:
      result.xNonce = result.xSched.nonceList.eq(item.tx.nonce).value.data


proc getInxImpl(gt: var TxSenderTab; item: TxItemRef): Result[TxSenderInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxSenderInx

  block:
    let rc = gt.addrList.eq(item.sender)
    if rc.isOk:
      inxData.sAddr = rc.value.data
    else:
      return err()
  # exclusive sub-tables
  block:
    let sched = item.local.toSenderLR
    inxData.lrSched = inxData.sAddr.schedList[sched]
    if inxData.lrSched.isNil:
      return err()
  block:
    let rc = inxData.lrSched.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      inxData.lrNonce = rc.value.data
    else:
      return err()
  # merged sub-table
  block:
    inxData.xSched = inxData.sAddr.schedList[txSenderAny]
    inxData.xNonce = inxData.xSched.nonceList.eq(item.tx.nonce).value.data

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(gt: var TxSenderTab; size = 10) =
  ## Optional constructor
  gt.size = 0
  gt.addrList.init


proc txInsert*(gt: var TxSenderTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = gt.mkInxImpl(item)
  if not inx.lrNonce.itemList.hasKey(item):
    discard inx.lrNonce.itemList.append(item)
    discard inx.xNonce.itemList.append(item)
    gt.size.inc
    inx.sAddr.size.inc
    inx.lrSched.size.inc
    inx.xSched.size.inc


proc txDelete*(gt: var TxSenderTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = gt.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    inx.lrNonce.itemList.del(item)
    inx.xNonce.itemList.del(item)
    gt.size.dec
    inx.sAddr.size.dec
    inx.lrSched.size.dec
    inx.xSched.size.dec

    if inx.lrNonce.itemList.len == 0:
      discard inx.lrSched.nonceList.delete(item.tx.nonce)
      if inx.lrSched.nonceList.len == 0:
        let sched = item.local.toSenderLR
        inx.sAddr.schedList[sched] = nil
        if inx.sAddr.schedList[not sched].isNil:
          discard gt.addrList.delete(item.sender)

      if inx.xNonce.itemList.len == 0:
        discard inx.xSched.nonceList.delete(item.tx.nonce)
        if inx.xSched.nonceList.len == 0:
          inx.sAddr.schedList[txSenderAny] = nil
    return true


proc txVerify*(gt: var TxSenderTab): Result[void,(TxSenderInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## walk `EthAddress` > `TxSenderSchedule` > `AccountNonce` > items
  var allCount = 0

  block:
    let rc = gt.addrList.verify
    if rc.isErr:
      return err((txSenderVfyRbTree, keeQuOk))

  var rcAddr = gt.addrList.ge(minEthAddress)
  while rcAddr.isOk:
    var addrCount = 0
    let (addrKey, addrData) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = gt.addrList.gt(addrKey)

    # at lest ((local or remote) and merged) lists must be available
    if addrData.nActive == 0:
      return err((txSenderVfyLeafEmpty, keeQuOk))
    if addrData.schedList[txSenderAny].isNil:
      return err((txSenderVfyLeafEmpty, keeQuOk))

    var
      lrCount = 0
      xCount = 0
    for sched in TxSenderSchedule:
      let schedData = addrData.schedList[sched]

      if not schedData.isNil:
        block:
          let rc = schedData.nonceList.verify
          if rc.isErr:
            return err((txSenderVfyRbTree, keeQuOk))

        var schedCount = 0
        var rcNonce = schedData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = schedData.nonceList.gt(nonceKey)

          if sched == txSenderAny:
            xCount += nonceData.itemList.len
          else:
            allCount += nonceData.itemList.len
            addrCount += nonceData.itemList.len
            lrCount += nonceData.itemList.len

          schedCount += nonceData.itemList.len

          if nonceData.itemList.len == 0:
            return err((txSenderVfyLeafEmpty, keeQuOk))

          let rcItem = nonceData.itemList.verify
          if rcItem.isErr:
            return err((txSenderVfyLeafQueue, rcItem.error[2]))

        # end while
        if schedCount != schedData.size:
          return err((txSenderVfySize, keeQuOk))

    # end for
    if addrCount != addrData.size:
      return err((txSenderVfySize, keeQuOk))
    if lrCount != addrData.size:
      return err((txSenderVfySize, keeQuOk))
    if xCount != addrData.size:
      return err((txSenderVfySize, keeQuOk))

  # end while
  if allCount != gt.size:
    return err((txSenderVfySize, keeQuOk))

  ok()

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(gt: var TxSenderTab): int {.inline.} =
  gt.addrList.len

# ------------------------------------------------------------------------------
# Public SLst ops -- `EthAddress` (level 0)
# ------------------------------------------------------------------------------

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


proc eq*(schedData: TxSenderSchedRef; local: bool):
       Result[TxSenderNoncePair,RbInfo] {.inline.} =
  ## Return local, or remote lists for argument `sender`.
  let
    sched = local.toSenderLR
    nonceData = schedData.schedList[sched]
  if not nonceData.isNil:
    return ok(TxSenderNoncePair(key: sched, data: nonceData))
  err(rbNotFound)

proc eq*(rc: SLstResult[EthAddress,TxSenderSchedRef]; local: bool):
       Result[TxSenderNoncePair,RbInfo] {.inline.} =
  ## Return local, or remote lists for argument `sender`.
  if rc.isOK:
    return rc.value.data.eq(local)
  err(rc.error)

proc any*(schedData: TxSenderSchedRef):
        Result[TxSenderNoncePair,RbInfo] {.inline.} =
  ## Return merged local + remote list for argument `sender`.
  let nonceData = schedData.schedList[txSenderAny]
  if not nonceData.isNil:
    return ok(TxSenderNoncePair(key: txSenderAny, data: nonceData))
  err(rbNotFound)

proc any*(rc: SLstResult[EthAddress,TxSenderSchedRef]):
        Result[TxSenderNoncePair,RbInfo] {.inline.} =
  ## Return merged local + remote list for argument `sender`.
  if rc.isOK:
    return rc.value.data.any
  err(rc.error)

# ------------------------------------------------------------------------------
# Public SLst ops -- `AccountNonce` (level 2)
# ------------------------------------------------------------------------------

proc len*(nonceData: TxSenderNonceRef): int {.inline.} =
  let rc = nonceData.nonceList.len


proc nItems*(nonceData: TxSenderNonceRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  nonceData.size

proc nItems*(rc: Result[TxSenderNoncePair,RbInfo]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc eq*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  nonceData.nonceList.eq(nonce)

proc eq*(rc: Result[TxSenderNoncePair,RbInfo]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.eq(nonce)
  err(rc.error)


proc ge*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  nonceData.nonceList.ge(nonce)

proc ge*(rc: Result[TxSenderNoncePair,RbInfo]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.ge(nonce)
  err(rc.error)


proc gt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  nonceData.nonceList.gt(nonce)

proc gt*(rc: Result[TxSenderNoncePair,RbInfo]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.gt(nonce)
  err(rc.error)


proc le*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  nonceData.nonceList.le(nonce)

proc le*(rc: Result[TxSenderNoncePair,RbInfo]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.le(nonce)
  err(rc.error)


proc lt*(nonceData: TxSenderNonceRef; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  nonceData.nonceList.lt(nonce)

proc lt*(rc: Result[TxSenderNoncePair,RbInfo]; nonce: AccountNonce):
       SLstResult[AccountNonce,TxSenderItemRef] {.inline.} =
  if rc.isOK:
    return rc.value.data.lt(nonce)
  err(rc.error)

# ------------------------------------------------------------------------------
# Public KeeQu ops -- traversal functions (level 3)
# ------------------------------------------------------------------------------

proc nItems*(itemData: TxSenderItemRef): int {.inline.} =
  itemData.itemList.len

proc nItems*(rc: SLstResult[AccountNonce,TxSenderItemRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc first*(itemData: TxSenderItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.first

proc first*(rc: SLstResult[AccountNonce,TxSenderItemRef]):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.first
  err()


proc last*(itemData: TxSenderItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.last

proc last*(rc: SLstResult[AccountNonce,TxSenderItemRef]):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.last
  err()


proc next*(itemData: TxSenderItemRef; item: TxItemRef):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.next(item)

proc next*(rc: SLstResult[AccountNonce,TxSenderItemRef]; item: TxItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.next(item)
  err()


proc prev*(itemData: TxSenderItemRef; item: TxItemRef):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.prev(item)

proc prev*(rc: SLstResult[AccountNonce,TxSenderItemRef]; item: TxItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.prev(item)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
