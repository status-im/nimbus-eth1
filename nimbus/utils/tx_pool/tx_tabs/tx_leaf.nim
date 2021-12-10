# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool, Leaf Items List
## =================================
##

import
  ../../keequ,
  ../../slst,
  ../tx_info,
  ../tx_item,
  eth/common,
  stew/results

type
  TxLeafItemRef* = ref object ##\
    ## All transaction items accessed by the same index are chronologically
    ## queued.
    itemList: KeeQuNV[TxItemRef]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(leaf: TxLeafItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $leaf.itemList.len

# ------------------------------------------------------------------------------
# Public leaf list helpers
# ------------------------------------------------------------------------------

proc txInit*(leaf: TxLeafItemRef; size = 1) =
  leaf.itemList.init(size)

proc txNew*(T: type TxLeafItemRef; size = 1): T =
  new result
  result.txInit(size)

proc txAppend*(leaf: TxLeafItemRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  leaf.itemList.append(item)

proc txFetch*(leaf: TxLeafItemRef): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Fifo mode: get oldest item
  leaf.itemList.shift

proc txDelete*(leaf: TxLeafItemRef; item: TxItemRef): bool
    {.gcsafe,raises: [Defect,KeyError].} =
  leaf.itemList.delete(item).isOK

proc txClear*(leaf: TxLeafItemRef): int
    {.gcsafe,raises: [Defect,KeyError].} =
  result = leaf.itemList.len
  leaf.itemList.clear

proc txVerify*(leaf: TxLeafItemRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = leaf.itemList.verify
  if rc.isErr:
    return err(txInfoVfyLeafQueue)
  ok()

# ------------------------------------------------------------------------------
# Public KeeQu ops -- traversal functions
# ------------------------------------------------------------------------------

proc nItems*(itemData: TxLeafItemRef): int {.inline.} =
  itemData.itemList.len

proc nItems*[T](rc: SLstResult[T,TxLeafItemRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc first*(itemData: TxLeafItemRef): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.first

proc first*[T](rc: SLstResult[T,TxLeafItemRef]): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Seen as a sub-list to an `SLst` parent
  if rc.isOK:
    return rc.value.data.first
  err()


proc last*(itemData: TxLeafItemRef): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.last

proc last*[T](rc: SLstResult[T,TxLeafItemRef]): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Seen as a sub-list to an `SLst` parent
  if rc.isOK:
    return rc.value.data.last
  err()


proc next*(itemData: TxLeafItemRef;
           item: TxItemRef): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.next(item)

proc next*[T](rc: SLstResult[T,TxLeafItemRef];
              item: TxItemRef): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Seen as a sub-list to an `SLst` parent
  if rc.isOK:
    return rc.value.data.next(item)
  err()


proc prev*(itemData: TxLeafItemRef; item: TxItemRef):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.prev(item)

proc prev*[T](rc: SLstResult[T,TxLeafItemRef];
              item: TxItemRef): Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  ## Seen as a sub-list to an `SLst` parent
  if rc.isOK:
    return rc.value.data.prev(item)
  err()

# ------------------------------------------------------------------------------
# Public KeeQu ops -- iterators
# ------------------------------------------------------------------------------

iterator walkItems*(itemData: TxLeafItemRef): TxItemRef
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Walk over leaf item list
  var rcItem = itemData.itemList.first
  while rcItem.isOk:
    let item = rcItem.value
    rcItem = itemData.itemList.next(item)
    yield item

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
