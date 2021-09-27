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
  ../tx_info,
  ../tx_item,
  ./tx_leaf,
  eth/common,
  stew/results

type
  TxTipCapTab* = object ##\
    ## Generic item list indexed by gas price
    size: int
    gasList: SLst[GasInt,TxLeafItemRef]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(leaf: TxLeafItemRef): string =
  ## Needed by `rq.verify()` for printing error messages
  $leaf.nItems

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc txInit*(gp: var TxTipCapTab) =
  gp.size = 0
  gp.gasList.init


proc txInsert*(gp: var TxTipCapTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Unconitionally add `(key,val)` pair to list. This might lead to
  ## multiple leaf values per argument `key`.
  var
    key = item.tx.gasTipCap
    rc = gp.gasList.insert(key)
  if rc.isOk:
    rc.value.data = txNew(type TxLeafItemRef)
  else:
    rc = gp.gasList.eq(key)
  if rc.value.data.txAppend(item):
    gp.size.inc


proc txDelete*(gp: var TxTipCapTab; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove `(key,val)` pair from list.
  var
    key = item.tx.gasTipCap
    rc = gp.gasList.eq(key)
  if rc.isOk:
    if rc.value.data.txDelete(item):
      gp.size.dec
      if rc.value.data.nItems == 0:
        discard gp.gasList.delete(key)


proc txVerify*(gp: var TxTipCapTab): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  var count = 0

  block:
    let rc = gp.gasList.verify
    if rc.isErr:
      return err(txInfoVfyTipCapList)

  var rcGas = gp.gasList.ge(GasInt.low)
  while rcGas.isOk:
    var (gasKey, itemData) = (rcGas.value.key, rcGas.value.data)
    rcGas = gp.gasList.gt(gasKey)

    count += itemData.nItems
    if itemData.nItems == 0:
      return err(txInfoVfyTipCapLeafEmpty)

    block:
      let rc = itemData.txVerify
      if rc.isErr:
        return err(txInfoVfyTipCapLeafEmpty)

  if count != gp.size:
    return err(txInfoVfyTipCapTotal)

  ok()

# ------------------------------------------------------------------------------
# Public SLst ops -- `GasInt` (level 0)
# ------------------------------------------------------------------------------

proc nItems*(gp: var TxTipCapTab): int {.inline.} =
  gp.size

proc len*(gp: var TxTipCapTab): int {.inline.} =
  gp.gasList.len

proc eq*(gp: var TxTipCapTab; key: GasInt):
       SLstResult[GasInt,TxLeafItemRef] {.inline.} =
  gp.gasList.eq(key)

proc ge*(gp: var TxTipCapTab; key: GasInt):
       SLstResult[GasInt,TxLeafItemRef] {.inline.} =
  gp.gasList.ge(key)

proc gt*(gp: var TxTipCapTab; key: GasInt):
       SLstResult[GasInt,TxLeafItemRef] {.inline.} =
  gp.gasList.gt(key)

proc le*(gp: var TxTipCapTab; key: GasInt):
       SLstResult[GasInt,TxLeafItemRef] {.inline.} =
  gp.gasList.le(key)

proc lt*(gp: var TxTipCapTab; key: GasInt):
       SLstResult[GasInt,TxLeafItemRef] {.inline.} =
  gp.gasList.lt(key)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
