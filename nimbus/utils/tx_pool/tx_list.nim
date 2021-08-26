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
  ../rnd_qu,
  ../slst,
  ./tx_item,
  eth/common,
  stew/results

type
  TxMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxItemList* = ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    RndQuRef[TxItemRef,TxMark]

  TxGasItemLst* = ##\
    ## Generic item list indexed by gas price
    SLstRef[GasInt,TxItemList]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private, helpers for debugging and pretty printing
# ------------------------------------------------------------------------------

proc `$`(rq: TxItemList): string =
  ## Needed by `rq.verify()` for printing error messages
  $rq.len

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(itemRef: TxItemRef): Hash =
  ## Needed for the `TxItemList` underlying table
  cast[pointer](itemRef).hash

# ------------------------------------------------------------------------------
# Private, generic list helpers
# ------------------------------------------------------------------------------

proc leafInsert[L,K](lst: L; key: K; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Unconitionally add `(key,val)` pair to list. This might lead to
  ## multiple leaf values per argument `key`.
  var rc = lst.insert(key)
  if rc.isOk:
    rc.value.data = newRndQu[TxItemRef,TxMark](1)
  else:
    rc = lst.eq(key)
  var dupList = rc.value.data
  discard dupList.append(val)

proc leafDelete[L,K](lst: L; key: K; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Remove `(key,val)` pair from list.
  var rc = lst.eq(key)
  if rc.isOk:
    var dupList = rc.value.data
    dupList.del(val)
    if dupList.len == 0:
      discard lst.delete(key)

proc leafDelete[L,K](lst: L; key: K) =
  ## For argument `key` remove all `(key,value)` pairs from list for some
  ## value.
  lst.delete(key)

# ------------------------------------------------------------------------------
# Public gas price list helpers
# ------------------------------------------------------------------------------

proc newGasItemLst*(): TxGasItemLst =
  newSLst[GasInt,TxItemList]()

proc txInsert*(gp: TxGasItemLst; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  gp.leafInsert(key,val)

proc txDelete*(gp: TxGasItemLst; key: GasInt; val: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  gp.leafDelete(key,val)

proc txVerify*(gp: TxGasItemLst): RbInfo
    {.gcsafe, raises: [Defect,CatchableError].} =
  let rc = gp.verify
  if rc.isErr:
    return rc.error[1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
