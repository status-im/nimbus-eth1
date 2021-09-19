# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## List And Queue Structures For Transaction Pool
## ==============================================
##
## Ackn: Vaguely inspired by
## `tx_list.go <https://github.com/ethereum/go-ethereum/blob/master/core/tx_list.go>`_
##

import
  ../../keequ,
  ../../slst,
  ../tx_item,
  eth/common,
  stew/results

type
  TxGasInfo* = enum
    txGasOk = 0
    txGasVfyRbTree    ## Corrupted RB tree
    txGasVfyLeafEmpty ## Empty leaf list
    txGasVfyLeafQueue ## Corrupted leaf list
    txGasVfySize      ## Size count mismatch

  TxGasItemRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    itemList: KeeQuNV[TxItemRef]

  TxGasTab* = object ##\
    ## Generic item list indexed by gas price
    size: int
    gasList: SLst[GasInt,TxGasItemRef]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(rq: TxGasItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.itemList.len

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc txInit*(gp: var TxGasTab) =
  gp.size = 0
  gp.gasList.init


proc txInsert*(gp: var TxGasTab; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Unconitionally add `(key,val)` pair to list. This might lead to
  ## multiple leaf values per argument `key`.
  var rc = gp.gasList.insert(key)
  if rc.isOk:
    rc.value.data = TxGasItemRef(
      itemList: init(type KeeQuNV[TxItemRef], initSize = 1))
  else:
    rc = gp.gasList.eq(key)
  if not rc.value.data.itemList.hasKey(val):
    discard rc.value.data.itemList.append(val)
    gp.size.inc


proc txDelete*(gp: var TxGasTab; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove `(key,val)` pair from list.
  var rc = gp.gasList.eq(key)
  if rc.isOk:
    if rc.value.data.itemList.hasKey(val):
      rc.value.data.itemList.del(val)
      gp.size.dec
      if rc.value.data.itemList.len == 0:
        discard gp.gasList.delete(key)


proc txVerify*(gp: var TxGasTab): Result[void,(TxGasInfo,KeeQuInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  var count = 0

  let sRc = gp.gasList.verify
  if sRc.isErr:
    return err((txGasVfyRbTree, keeQuOk))

  var wRc = gp.gasList.ge(GasInt.low)
  while wRc.isOk:
    var itQ = wRc.value.data
    wRc = gp.gasList.gt(wRc.value.key)

    count += itQ.itemList.len
    if itQ.itemList.len == 0:
      return err((txGasVfyLeafEmpty, keeQuOk))

    let qRc = itQ.itemList.verify
    if qRc.isErr:
      return err((txGasVfyLeafQueue, qRc.error[2]))

  if count != gp.size:
    return err((txGasVfySize, keeQuOk))
  ok()

# ------------------------------------------------------------------------------
# Public SLst ops -- `GasInt` (level 0)
# ------------------------------------------------------------------------------

proc nItems*(gp: var TxGasTab): int {.inline.} =
  gp.size

proc len*(gp: var TxGasTab): int {.inline.} =
  gp.gasList.len

proc eq*(gp: var TxGasTab; key: GasInt):
       SLstResult[GasInt,TxGasItemRef] {.inline.} =
  gp.gasList.eq(key)

proc ge*(gp: var TxGasTab; key: GasInt):
       SLstResult[GasInt,TxGasItemRef] {.inline.} =
  gp.gasList.ge(key)

proc gt*(gp: var TxGasTab; key: GasInt):
       SLstResult[GasInt,TxGasItemRef] {.inline.} =
  gp.gasList.gt(key)

proc le*(gp: var TxGasTab; key: GasInt):
       SLstResult[GasInt,TxGasItemRef] {.inline.} =
  gp.gasList.le(key)

proc lt*(gp: var TxGasTab; key: GasInt):
       SLstResult[GasInt,TxGasItemRef] {.inline.} =
  gp.gasList.lt(key)

# ------------------------------------------------------------------------------
# Public KeeQu ops -- traversal functions (level 1)
# ------------------------------------------------------------------------------

proc nItems*(itemData: TxGasItemRef): int {.inline.} =
  itemData.itemList.len

proc nItems*(rc: SLstResult[GasInt,TxGasItemRef]): int {.inline.} =
  if rc.isOK:
    return rc.value.data.nItems
  0


proc first*(itemData: TxGasItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.first

proc first*(rc: SLstResult[GasInt,TxGasItemRef]):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.first
  err()


proc last*(itemData: TxGasItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.last

proc last*(rc: SLstResult[GasInt,TxGasItemRef]):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.last
  err()


proc next*(itemData: TxGasItemRef; item: TxItemRef):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.next(item)

proc next*(rc: SLstResult[GasInt,TxGasItemRef]; item: TxItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.next(item)
  err()


proc prev*(itemData: TxGasItemRef; item: TxItemRef):
         Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  itemData.itemList.prev(item)

proc prev*(rc: SLstResult[GasInt,TxGasItemRef]; item: TxItemRef):
          Result[TxItemRef,void]
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  if rc.isOK:
    return rc.value.data.prev(item)
  err()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
