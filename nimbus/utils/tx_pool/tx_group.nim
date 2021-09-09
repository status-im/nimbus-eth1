# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Table Wrapper For Transaction Pool
## ==================================
##

import
  std/[math, tables],
  ../keequ,
  ./tx_item,
  eth/[common],
  stew/results

type
  TxGroupInfo* = enum
    txGroupOk = 0
    txGroupVfyQueue     ## Corrupted address queue/table structure
    txGroupVfyLeafEmpty ## Empty leaf list
    txGroupVfyLeafQueue ## Corrupted leaf list
    txGroupVfySize      ## Size count mismatch

  TxGroupMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxGroupItemsRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    itemList*: KeeQu[TxItemRef,TxGroupMark]

  TxGroupAddr* = object ##\
    ## Per address table
    size: int
    q: KeeQu[EthAddress,TxGroupItemsRef]

  TxGroupAddrPair* = ##\
    ## Queue handler wrapper, needed in `first()`, `next()`, etc.
    KeeQuPair[EthAddress,TxGroupItemsRef]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(t: var TxGroupAddr; size = 10) =
  ## Optional constructor
  t.size = 0
  t.q.init(size)


proc txInsert*(t: var TxGroupAddr; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  if not t.q.hasKey(ethAddr):
    t.q[ethAddr] = TxGroupItemsRef(
      itemList: initKeeQu[TxItemRef,TxGroupMark](1))
  elif t.q[ethAddr].itemList.hasKey(item):
    return
  t.q[ethAddr].itemList[item] = 0
  t.size.inc


proc txDelete*(t: var TxGroupAddr; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  if t.q.hasKey(ethAddr) and t.q[ethAddr].itemList.hasKey(item):
    t.q[ethAddr].itemList.del(item)
    t.size.dec
    if t.q[ethAddr].itemList.len == 0:
      t.q.del(ethAddr)


proc txVerify*(t: var TxGroupAddr): Result[void,(TxGroupInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  var count = 0

  let rc = t.q.verify
  if rc.isErr:
    return err((txGroupVfyQueue,rc.error[2]))

  for itQ in t.q.nextValues:
    count += itQ.itemList.len
    if itQ.itemList.len == 0:
      return err((txGroupVfyLeafEmpty, keeQuOk))

    let rc = itQ.itemList.verify
    if rc.isErr:
      return err((txGroupVfyLeafQueue, rc.error[2]))

  if count != t.size:
    return err((txGroupVfySize, keeQuOk))
  ok()


proc nLeaves*(t: var TxGroupAddr): int {.inline.} =
  t.size


# Table ops
proc`[]`*(t: var TxGroupAddr; key: EthAddress): auto
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  t.q[key]

proc hasKey*(t: var TxGroupAddr; key: EthAddress): auto {.inline.} =
  t.q.hasKey(key)

proc len*(t: var TxGroupAddr): auto {.inline.} = t.q.len

proc first*(t: var TxGroupAddr): auto {.gcsafe,raises: [Defect,KeyError].} =
  t.q.first

proc next*(t: var TxGroupAddr;
           key: EthAddress): auto {.gcsafe,raises: [Defect,KeyError].} =
  t.q.next(key)


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
