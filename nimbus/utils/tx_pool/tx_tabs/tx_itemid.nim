# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Table `local/remote` > `itemID` > `insertion-time-rank`
## ========================================================================
##

import
  std/[tables],
  ../../keequ,
  ../../keequ/kq_debug,
  ../tx_info,
  ../tx_item,
  eth/common,
  stew/results

type
  TxItemIdItemRef* = ref object ##\
    ## All transaction items accessed by the same index are chronologically
    ## queued and indexed by the `itemID`.
    itemList: KeeQu[Hash256,TxItemRef]

  TxItemIdTab* = object ##\
    ## Chronological queue and ID table, fifo
    size: int
    isLocalList: array[bool,TxItemIdItemRef]

  TxItemIdInx = object ##\
    ## Internal access data
    local: TxItemIdItemRef

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc mkInxImpl(aq: var TxItemIdTab; item: TxItemRef): TxItemIdInx =
  result.local = aq.isLocalList[item.local]
  if result.local.isNil:
    new result.local
    result.local.itemList.init(1)
    aq.isLocalList[item.local] = result.local


proc getInxImpl(aq: var TxItemIdTab; item: TxItemRef): Result[TxItemIdInx,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  var inxData: TxItemIdInx

  inxData.local = aq.isLocalList[item.local]
  if inxData.local.isNil:
    return err()

  ok(inxData)

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(aq: var TxItemIdTab) =
  aq.size = 0
  aq.isLocalList.reset


proc txAppend*(aq: var TxItemIdTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  let inx = aq.mkInxImpl(item)
  discard inx.local.itemList.append(item.itemID,item)
  aq.size.inc


proc txDelete*(aq: var TxItemIdTab; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = aq.getInxImpl(item)
  if rc.isOK:
    let inx = rc.value

    inx.local.itemList.del(item.itemID)
    aq.size.dec

    if inx.local.itemList.len == 0:
      aq.isLocalList[item.local] = nil
    return true


proc txVerify*(aq: var TxItemIdTab): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,KeyError].} =
  var allCount = 0

  for sched in [true,false]:
    if not aq.isLocalList[sched].isNil:
      let rc = aq.isLocalList[sched].itemList.verify
      if rc.isErr:
        return err(txInfoVfyItemIdList)
      allCount += aq.isLocalList[sched].itemList.len

  if allCount != aq.size:
    return err(txInfoVfyItemIdTotal)

  ok()

# ------------------------------------------------------------------------------
# Public array ops -- `TxItemIdSchedule` (level 0)
# ------------------------------------------------------------------------------

proc len*(aq: var TxItemIdTab): int {.inline.} =
  ## Number of local + remote slots (0 .. 2)
  if not aq.isLocalList[true].isNil:
    result.inc
  if not aq.isLocalList[false].isNil:
    result.inc

proc nItems*(aq: var TxItemIdTab): int {.inline.} =
  aq.size

proc eq*(aq: var TxItemIdTab; local: bool):
       Result[KeeQuPair[bool,TxItemIdItemRef],void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  let itemData = aq.isLocalList[local]
  if itemData.isNil:
    return err()
  toKeeQuResult(key = local, data = itemData)

# ------------------------------------------------------------------------------
# Public KeeQu ops -- traversal functions (level 1)
# ------------------------------------------------------------------------------

proc nItems*(itemData: TxItemIdItemRef): int {.inline.} =
  itemData.itemList.len

proc nItems*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc hasKey*(itemData: TxItemIdItemRef;
             itemID: Hash256): bool {.inline.} =
  itemData.itemList.hasKey(itemID)

proc hasKey*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void];
             itemID: Hash256): bool {.inline.} =
  if rc.isOK:
    return rc.value.data.hasKey(itemID)
  false


proc eq*(itemData: TxItemIdItemRef;
         itemID: Hash256): Result[TxItemRef,void]
       {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.eq(itemID)

proc eq*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void];
         itemID: Hash256): Result[TxItemRef,void]
       {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.itemList.eq(itemID)
  err()


proc first*(itemData: TxItemIdItemRef):
            Result[KeeQuPair[Hash256,TxItemRef],void]
          {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.first

proc first*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void]):
            Result[KeeQuPair[Hash256,TxItemRef],void]
          {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.first
  err()


proc last*(itemData: TxItemIdItemRef):
           Result[KeeQuPair[Hash256,TxItemRef],void]
         {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.last

proc last*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void]):
           Result[KeeQuPair[Hash256,TxItemRef],void]
         {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.last
  err()


proc next*(itemData: TxItemIdItemRef; key: Hash256):
           Result[KeeQuPair[Hash256,TxItemRef],void]
         {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.next(key)

proc next*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void]; key: Hash256):
           Result[KeeQuPair[Hash256,TxItemRef],void]
         {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.next(key)
  err()


proc prev*(itemData: TxItemIdItemRef; key: Hash256):
           Result[KeeQuPair[Hash256,TxItemRef],void]
         {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.prev(key)

proc prev*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void]; key: Hash256):
           Result[KeeQuPair[Hash256,TxItemRef],void]
         {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.prev(key)
  err()

# ------------------------------------------------------------------------------
# Public KeeQu ops -- iterators (level 1)
# ------------------------------------------------------------------------------

iterator walkItems*(itemData: TxItemIdItemRef): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over itemID item list
  var rcItem = itemData.itemList.first
  while rcItem.isOk:
    let (key, item) = (rcItem.value.key, rcItem.value.data)
    rcItem = itemData.itemList.next(key)
    yield item

iterator walkItems*(rc: Result[KeeQuPair[bool,TxItemIdItemRef],void]): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over itemID item list
  if rc.isOK:
    var rcItem = rc.value.data.itemList.first
    while rcItem.isOk:
      let (key, item) = (rcItem.value.key, rcItem.value.data)
      rcItem = rc.value.data.itemList.next(key)
      yield item

# ------------------------------------------------------------------------------
# Public ops -- combined methods (level 0 + 1)
# ------------------------------------------------------------------------------

proc hasKey*(aq: var TxItemIdTab; itemID: Hash256): bool =
  block:
    let itemData = aq.isLocalList[true]
    if not itemData.isNil:
      if itemData.itemList.hasKey(itemID):
        return true
  block:
    let itemData = aq.isLocalList[false]
    if not itemData.isNil:
      if itemData.itemList.hasKey(itemID):
        return true
  false

proc eq*(aq: var TxItemIdTab; itemID: Hash256):
       Result[TxItemRef,void] {.gcsafe,raises: [Defect,KeyError].} =
  block:
    let itemData = aq.isLocalList[true]
    if not itemData.isNil:
      let rc = itemData.itemList.eq(itemID)
      if rc.isOK:
        return ok(rc.value)
  block:
    let itemData = aq.isLocalList[false]
    if not itemData.isNil:
      let rc = itemData.itemList.eq(itemID)
      if rc.isOK:
        return ok(rc.value)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
