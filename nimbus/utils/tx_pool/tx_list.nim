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
  std/[hashes],
  ../keequ,
  ../slst,
  ./tx_item,
  eth/common,
  stew/results

type
  TxListInfo* = enum
    txListOk = 0
    txListVfyRbTree    ## Corrupted RB tree
    txListVfyLeafEmpty ## Empty leaf list
    txListVfyLeafQueue ## Corrupted leaf list
    txListVfySize      ## Size count mismatch

  TxListMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxListItems* = ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    KeeQu[TxItemRef,TxListMark]

  TxGasItemLst* = object ##\
    ## Generic item list indexed by gas price
    size: int
    l: SLst[GasInt,TxListItems]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(rq: var TxListItems): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.len

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(itemRef: TxItemRef): Hash =
  ## Needed for the `TxListItems` underlying table
  cast[pointer](itemRef).hash

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc txInit*(gp: var TxGasItemLst) =
  gp.size = 0
  gp.l.init


proc txInsert*(gp: var TxGasItemLst; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Unconitionally add `(key,val)` pair to list. This might lead to
  ## multiple leaf values per argument `key`.
  var rc = gp.l.insert(key)
  if rc.isOk:
    rc.value.data.init(1)
  else:
    rc = gp.l.eq(key)
  if not rc.value.data.hasKey(val):
    discard rc.value.data.append(val,0)
    gp.size.inc


proc txDelete*(gp: var TxGasItemLst; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove `(key,val)` pair from list.
  var rc = gp.l.eq(key)
  if rc.isOk:
    if rc.value.data.hasKey(val):
      rc.value.data.del(val)
      gp.size.dec
      if rc.value.data.len == 0:
        discard gp.l.delete(key)


proc txVerify*(gp: var TxGasItemLst): Result[void,(TxListInfo,KeeQuInfo)]
    {.gcsafe, raises: [Defect,CatchableError].} =
  var count = 0

  let sRc = gp.l.verify
  if sRc.isErr:
    return err((txListVfyRbTree, keeQuOk))

  var wRc = gp.l.ge(GasInt.low)
  while wRc.isOk:
    var itQ = wRc.value.data
    wRc = gp.l.gt(wRc.value.key)

    count += itQ.len
    if itQ.len == 0:
      return err((txListVfyLeafEmpty, keeQuOk))

    let qRc = itQ.verify
    if qRc.isErr:
      return err((txListVfyLeafQueue, qRc.error[2]))

  if count != gp.size:
    return err((txListVfySize, keeQuOk))
  ok()


proc nLeaves*(gp: var TxGasItemLst): int {.inline.} =
  gp.size


# Slst ops
proc  eq*(gp: var TxGasItemLst; key: GasInt): auto {.inline.} = gp.l.eq(key)
proc  ge*(gp: var TxGasItemLst; key: GasInt): auto {.inline.} = gp.l.ge(key)
proc  gt*(gp: var TxGasItemLst; key: GasInt): auto {.inline.} = gp.l.gt(key)
proc  le*(gp: var TxGasItemLst; key: GasInt): auto {.inline.} = gp.l.le(key)
proc  lt*(gp: var TxGasItemLst; key: GasInt): auto {.inline.} = gp.l.lt(key)
proc len*(gp: var TxGasItemLst):              auto {.inline.} = gp.l.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
