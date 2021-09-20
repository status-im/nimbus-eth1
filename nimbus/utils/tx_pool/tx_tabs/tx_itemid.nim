# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Queue Structure For Transaction Pool
## ====================================
##
## Ackn: Vaguely inspired by the *txLookup* maps from
## `tx_pool.go <https://github.com/ethereum/go-ethereum/blob/887902ea4d7ee77118ce803e05085bd9055aa46d/core/tx_pool.go#L1646>`_
##

import
  std/[tables],
  ../../keequ,
  ../tx_info,
  ../tx_item,
  eth/common,
  stew/results

type
  TxItemIdSchedule* = enum ##\
    ## Sub-queues
    txItemIdLocal = 0
    txItemIdRemote = 1

  TxItemIdItemRef* = ref object ##\
    ## All transaction items accessed by the same index are chronologically
    ## queued and indexed by the `itemID`.
    itemList: KeeQu[Hash256,TxItemRef]

  TxItemIdTab* = object ##\
    ## Chronological queue and ID table, fifo
    size: int
    schedList: array[TxItemIdSchedule,TxItemIdItemRef]

  TxItemIdItemPair* = object ##\
    ## Intermediate result, somehow similar to
    ## `KeeQuPair` (only that the `key` field is read-only there)
    key*: bool
    data*: TxItemIdItemRef

  TxItemIdInx = object ##\
    ## Internal access data
    sched: TxItemIdItemRef
    other: TxItemIdItemRef # for append/re-assign

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `not`(sched: TxItemIdSchedule): TxItemIdSchedule {.inline.} =
  if sched == txItemIdLocal: txItemIdRemote else: txItemIdLocal

proc toItemIdSched*(local: bool): TxItemIdSchedule {.inline.} =
  if local: txItemIdLocal else: txItemIdRemote


proc mkInxImpl(aq: var TxItemIdTab; item: TxItemRef): TxItemIdInx =
  let sched = item.local.toItemIdSched
  block:
    result.other = aq.schedList[not sched]
  block:
    if aq.schedList[sched].isNil:
      new result.sched
      result.sched.itemList.init(1)
      aq.schedList[sched] = result.sched
    else:
      result.sched = aq.schedList[sched]


proc getInxImpl(aq: var TxItemIdTab; item: TxItemRef): Result[TxItemIdInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxItemIdInx

  block:
    let sched = item.local.toItemIdSched
    inxData.sched = aq.schedList[sched]
    if inxData.sched.isNil:
      return err()

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(aq: var TxItemIdTab) =
  aq.size = 0
  aq.schedList.reset


proc txAppend*(aq: var TxItemIdTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = aq.mkInxImpl(item)
  discard inx.sched.itemList.append(item.itemID,item)
  aq.size.inc


proc txDelete*(aq: var TxItemIdTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = aq.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    inx.sched.itemList.del(item.itemID)
    aq.size.dec

    if inx.sched.itemList.len == 0:
      let sched = item.local.toItemIdSched
      aq.schedList[sched] = nil
    return true


proc txVerify*(aq: var TxItemIdTab): Result[void,TxVfyError]
    {.gcsafe,raises: [Defect,KeyError].} =
  var allCount = 0

  for sched in TxItemIdSchedule:
    if not aq.schedList[sched].isNil:
      let rc = aq.schedList[sched].itemList.verify
      if rc.isErr:
        return err(txVfyItemIdList)
      allCount += aq.schedList[sched].itemList.len

  if allCount != aq.size:
    return err(txVfyItemIdTotal)

  ok()

# ------------------------------------------------------------------------------
# Public array ops -- `TxItemIdSchedule` (level 0)
# ------------------------------------------------------------------------------

proc len*(aq: var TxItemIdTab): int {.inline.} =
  ## Number of local + remote slots (0 .. 2)
  if not aq.schedList[txItemIdLocal].isNil:
    result.inc
  if not aq.schedList[txItemIdRemote].isNil:
    result.inc

proc nItems*(aq: var TxItemIdTab): int {.inline.} =
  aq.size

proc eq*(aq: var TxItemIdTab; local: bool):
       Result[TxItemIdItemPair,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  let itemData = aq.schedList[local.toItemIdSched]
  if not itemData.isNil:
    return ok(TxItemIdItemPair(key: local, data: itemData))
  err()

# ------------------------------------------------------------------------------
# Public KeeQu ops -- traversal functions (level 1)
# ------------------------------------------------------------------------------

proc nItems*(itemData: TxItemIdItemRef): int {.inline.} =
  itemData.itemList.len

proc nItems*(rc: Result[TxItemIdItemPair,void]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc hasKey*(itemData: TxItemIdItemRef; itemID: Hash256): bool
    {.inline.} =
  itemData.itemList.hasKey(itemID)

proc hasKey*(rc: Result[TxItemIdItemPair,void]; itemID: Hash256): bool
    {.inline.} =
  if rc.isOK:
    return rc.value.data.hasKey(itemID)
  false


proc eq*(itemData: TxItemIdItemRef; itemID: Hash256):
       Result[TxItemRef,void] {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.eq(itemID)

proc eq*(rc: Result[TxItemIdItemPair,void]; itemID: Hash256):
       Result[TxItemRef,void] {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.itemList.eq(itemID)
  err()


proc first*(itemData: TxItemIdItemRef):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.first

proc first*(rc: Result[TxItemIdItemPair,void]):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.first
  err()


proc last*(itemData: TxItemIdItemRef):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.last

proc last*(rc: Result[TxItemIdItemPair,void]):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.last
  err()


proc next*(itemData: TxItemIdItemRef; key: Hash256):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.next(key)

proc next*(rc: Result[TxItemIdItemPair,void]; key: Hash256):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.next(key)
  err()


proc prev*(itemData: TxItemIdItemRef; key: Hash256):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.prev(key)

proc prev*(rc: Result[TxItemIdItemPair,void]; key: Hash256):
          Result[KeeQuPair[Hash256,TxItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.prev(key)
  err()

# ------------------------------------------------------------------------------
# Public ops -- combined methods (level 0 + 1)
# ------------------------------------------------------------------------------

proc hasKey*(aq: var TxItemIdTab; itemID: Hash256): bool =
  block:
    let itemData = aq.schedList[txItemIdLocal]
    if not itemData.isNil:
      if itemData.itemList.hasKey(itemID):
        return true
  block:
    let itemData = aq.schedList[txItemIdRemote]
    if not itemData.isNil:
      if itemData.itemList.hasKey(itemID):
        return true
  false

proc eq*(aq: var TxItemIdTab; itemID: Hash256):
       Result[TxItemRef,void] {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let itemData = aq.schedList[txItemIdLocal]
    if not itemData.isNil:
      let rc = itemData.itemList.eq(itemID)
      if rc.isOK:
        return ok(rc.value)
  block:
    let itemData = aq.schedList[txItemIdRemote]
    if not itemData.isNil:
      let rc = itemData.itemList.eq(itemID)
      if rc.isOK:
        return ok(rc.value)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
