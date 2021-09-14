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
  ../keequ,
  ../slst,
  ./tx_item,
  eth/[common],
  stew/results

type
  TxGroupInfo* = enum
    txGroupOk = 0
    txGroupVfyRbTree    ## Corrupted RB tree
    txGroupVfyLeafEmpty ## Empty leaf list
    txGroupVfyLeafQueue ## Corrupted leaf list
    txGroupVfySize      ## Size count mismatch

  TxGroupSchedule = enum ##\
    ## Sub-queues
    TxGroupLocal = 0
    TxGroupRemote = 1

  TxGroupMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxGroupItemRef* = ref object ##\
    ## All transaction items accessed by the same index are chronologically
    ## queued.
    itemList*: KeeQu[TxItemRef,TxGroupMark]

  TxGroupNonceRef* = ref object ##\
    ## Sub-list ordered by `AccountNonce` values containing transaction
    ## item lists.
    size: int
    nonceList*: Slst[AccountNonce,TxGroupItemRef]

  TxGroupSchedRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    size: int
    schedList: array[TxGroupSchedule,TxGroupNonceRef]

  TxGroupTab* = object ##\
    ## Per address table
    size: int
    addrList: SLst[EthAddress,TxGroupSchedRef]

  TxGroupPair* = object ##\
    ## Walk result, needed in `first()`, `next()`, etc.
    key*: EthAddress
    data*: TxGroupSchedRef

  TxGroupInx = object ##\
    ## Internal access data
    sAddr: TxGroupSchedRef
    sched: TxGroupNonceRef
    nonce: TxGroupItemRef

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

proc nActive(gs: TxGroupSchedRef): int {.inline.} =
  ## Number of non-nil items
  if not gs.schedList[TxGroupLocal].isNil:
    result.inc
  if not gs.schedList[TxGroupRemote].isNil:
    result.inc

proc `$`(rq: TxGroupItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.itemList.len

proc `$`(rq: TxGroupSchedRef): string =
  ## Needed by `rq.verify()` for printing error messages
  var n = 0
  if not rq.schedList[TxGroupLocal].isNil: n.inc
  if not rq.schedList[TxGroupRemote].isNil: n.inc
  $n

#proc `$`(rq: TxGroupNonceRef): string =
#  ## Needed by `rq.verify()` for printing error messages
#  $rq.nonceList.len

proc cmp(a,b: EthAddress): int {.inline.} =
  ## mixin for SLst
  for n in 0 ..< EthAddress.len:
    if a[n] < b[n]:
      return -1
    if b[n] < a[n]:
      return 1

proc `not`(sched: TxGroupSchedule): TxGroupSchedule {.inline.} =
  if sched == TxGroupLocal: TxGroupRemote else: TxGroupLocal

proc toGroupSched*(local: bool): TxGroupSchedule {.inline.} =
  if local: TxGroupLocal else: TxGroupRemote


proc mkInxImpl(gt: var TxGroupTab; item: TxItemRef): TxGroupInx
    {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let rc = gt.addrList.insert(item.sender)
    if rc.isOk:
      new result.sAddr
      rc.value.data = result.sAddr
    else:
      result.sAddr = gt.addrList.eq(item.sender).value.data
  block:
    let sched = item.local.toGroupSched
    if result.sAddr.schedList[sched].isNil:
      new result.sched
      result.sched.nonceList.init
      result.sAddr.schedList[sched] = result.sched
    else:
      result.sched = result.sAddr.schedList[sched]
  block:
    let rc = result.sched.nonceList.insert(item.tx.nonce)
    if rc.isOk:
      new result.nonce
      result.nonce.itemList.init(1)
      rc.value.data = result.nonce
    else:
      result.nonce = result.sched.nonceList.eq(item.tx.nonce).value.data


proc getInxImpl(gt: var TxGroupTab; item: TxItemRef): Result[TxGroupInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxGroupInx

  block:
    let rc = gt.addrList.eq(item.sender)
    if rc.isOk:
      inxData.sAddr = rc.value.data
    else:
      return err()
  block:
    let sched = item.local.toGroupSched
    inxData.sched = inxData.sAddr.schedList[sched]
    if inxData.sched.isNil:
      return err()
  block:
    let rc = inxData.sched.nonceList.eq(item.tx.nonce)
    if rc.isOk:
      inxData.nonce = rc.value.data
    else:
      return err()

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(gt: var TxGroupTab; size = 10) =
  ## Optional constructor
  gt.size = 0
  gt.addrList.init


proc txInsert*(gt: var TxGroupTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction item to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = gt.mkInxImpl(item)
  if not inx.nonce.itemList.hasKey(item):
    discard inx.nonce.itemList.append(item,0)
    gt.size.inc
    inx.sAddr.size.inc
    inx.sched.size.inc


proc txDelete*(gt: var TxGroupTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = gt.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    inx.nonce.itemList.del(item)
    gt.size.dec
    inx.sAddr.size.dec
    inx.sched.size.dec

    if rc.value.nonce.itemList.len == 0:
      discard rc.value.sched.nonceList.delete(item.tx.nonce)
      if rc.value.sched.nonceList.len == 0:
        let sched = item.local.toGroupSched
        rc.value.sAddr.schedList[sched] = nil
        if rc.value.sAddr.schedList[not sched].isNil:
          discard gt.addrList.delete(item.sender)


proc txVerify*(gt: var TxGroupTab): Result[void,(TxGroupInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## walk `EthAddress` > `TxGroupSchedule` > `AccountNonce` > items
  var allCount = 0

  block:
    let rc = gt.addrList.verify
    if rc.isErr:
      return err((txGroupVfyRbTree, keeQuOk))

  var rcAddr = gt.addrList.ge(minEthAddress)
  while rcAddr.isOk:
    var addrCount = 0
    let (addrKey, addrData) = (rcAddr.value.key, rcAddr.value.data)
    rcAddr = gt.addrList.gt(addrKey)

    if addrData.nActive == 0:
      return err((txGroupVfyLeafEmpty, keeQuOk))

    for sched in TxGroupSchedule:
      let schedData = addrData.schedList[sched]

      if not schedData.isNil:
        block:
          let rc = schedData.nonceList.verify
          if rc.isErr:
            return err((txGroupVfyRbTree, keeQuOk))

        var schedCount = 0
        var rcNonce = schedData.nonceList.ge(AccountNonce.low)
        while rcNonce.isOk:
          let (nonceKey, nonceData) = (rcNonce.value.key, rcNonce.value.data)
          rcNonce = schedData.nonceList.gt(nonceKey)

          allCount += nonceData.itemList.len
          schedCount += nonceData.itemList.len
          addrCount  += nonceData.itemList.len

          if nonceData.itemList.len == 0:
            return err((txGroupVfyLeafEmpty, keeQuOk))

          let rcItem = nonceData.itemList.verify
          if rcItem.isErr:
            return err((txGroupVfyLeafQueue, rcItem.error[2]))

        # end while
        if schedCount != schedData.size:
          return err((txGroupVfySize, keeQuOk))

    # end for
    if addrCount != addrData.size:
      return err((txGroupVfySize, keeQuOk))

  # end while
  if allCount != gt.size:
    return err((txGroupVfySize, keeQuOk))

  ok()

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(gt: var TxGroupTab): auto {.inline.} =
  gt.addrList.len

proc len*(gs: TxGroupSchedRef): int {.inline.} =
  gs.nActive

# ------------------------------------------------------------------------------
# Public SLst ops -- `EthAddress` (level 0)
# ------------------------------------------------------------------------------

proc nLeaves*(gt: var TxGroupTab): int {.inline.} =
  ## Getter, total number of items in the list
  gt.size

proc eq*(gt: var TxGroupTab; sender: EthAddress): auto {.inline.} =
  let rc = gt.addrList.eq(sender)
  if rc.isOK:
    return Result[TxGroupSchedRef,void].ok(rc.value.data)
  err()

proc first*(gt: var TxGroupTab): Result[TxGroupPair,void] {.inline.} =
  let rc = gt.addrList.ge(minEthAddress)
  if rc.isErr:
    return err()
  ok(TxGroupPair(key: rc.value.key, data: rc.value.data))

proc last*(gt: var TxGroupTab): Result[TxGroupPair,void] {.inline.} =
  let rc = gt.addrList.le(maxEthAddress)
  if rc.isErr:
    return err()
  ok(TxGroupPair(key: rc.value.key, data: rc.value.data))

proc next*(gt: var TxGroupTab;
           key: EthAddress): Result[TxGroupPair,void] {.inline.} =
  let rc = gt.addrList.gt(key)
  if rc.isErr:
    return err()
  ok(TxGroupPair(key: rc.value.key, data: rc.value.data))

proc prev*(gt: var TxGroupTab;
           key: EthAddress): Result[TxGroupPair,void] {.inline.} =
  let rc = gt.addrList.lt(key)
  if rc.isErr:
    return err()
  ok(TxGroupPair(key: rc.value.key, data: rc.value.data))

# ------------------------------------------------------------------------------
# Public array ops -- `TxGroupSchedule` (level 1)
# ------------------------------------------------------------------------------

proc nLeaves*(gs: TxGroupSchedRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  gs.size

proc eq*(gs: TxGroupSchedRef;
         local: bool): Result[TxGroupNonceRef,void] {.inline.} =
  let nonceData = gs.schedList[local.toGroupSched]
  if nonceData.isNil:
    return err()
  ok(nonceData)

# ------------------------------------------------------------------------------
# Public, combined -- `EthAddress > TxGroupSchedule` (level 0 + 1)
# ------------------------------------------------------------------------------

proc eq*(gt: var TxGroupTab; sender: EthAddress; local: bool): auto {.inline.} =
  let rc = gt.eq(sender)
  if rc.isOk:
    return rc.value.eq(local)
  err()

# ------------------------------------------------------------------------------
# Public SLst ops -- `AccountNonce` (level 2)
# ------------------------------------------------------------------------------

proc nLeaves*(nl: TxGroupNonceRef): int {.inline.} =
  ## Getter, total number of items in the sub-list
  nl.size

proc len*(nl: TxGroupNonceRef): int {.inline.} =
  let rc = nl.nonceList.len

proc eq*(nl: TxGroupNonceRef; nonce: AccountNonce): auto {.inline.} =
  let rc = nl.nonceList.eq(nonce)
  if rc.isOK:
    return Result[TxGroupItemRef,void].ok(rc.value.data)
  err()

proc ge*(nl: TxGroupNonceRef; nonce: AccountNonce): auto {.inline.} =
  let rc = nl.nonceList.ge(nonce)
  if rc.isOK:
    return Result[TxGroupItemRef,void].ok(rc.value.data)
  err()

proc gt*(nl: TxGroupNonceRef; nonce: AccountNonce): auto {.inline.} =
  let rc = nl.nonceList.gt(nonce)
  if rc.isOK:
    return Result[TxGroupItemRef,void].ok(rc.value.data)
  err()

proc le*(nl: TxGroupNonceRef; nonce: AccountNonce): auto {.inline.} =
  let rc = nl.nonceList.le(nonce)
  if rc.isOK:
    return Result[TxGroupItemRef,void].ok(rc.value.data)
  err()

proc lt*(nl: TxGroupNonceRef; nonce: AccountNonce): auto {.inline.} =
  let rc = nl.nonceList.lt(nonce)
  if rc.isOK:
    return Result[TxGroupItemRef,void].ok(rc.value.data)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
