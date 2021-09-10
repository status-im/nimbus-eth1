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

  TxGroupSchedule* = enum ##\
    ## Sub-queues
    TxGroupLocal = 0
    TxGroupRemote = 1

  TxGroupMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxGroupItemsRef* = ref object ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    itemList: array[TxGroupSchedule, KeeQu[TxItemRef,TxGroupMark]]

  TxGroupAddr* = object ##\
    ## Per address table
    size: int
    q: KeeQu[EthAddress,TxGroupItemsRef]

  TxGroupAddrPair* = ##\
    ## Queue handler wrapper, needed in `first()`, `next()`, etc.
    KeeQuPair[EthAddress,TxGroupItemsRef]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `not`(sched: TxGroupSchedule): TxGroupSchedule {.inline.} =
  if sched == TxGroupLocal: TxGroupRemote else: TxGroupLocal

proc toGroupSched*(isLocal: bool): TxGroupSchedule {.inline.} =
  if isLocal: TxGroupLocal else: TxGroupRemote

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(t: var TxGroupAddr; size = 10) =
  ## Optional constructor
  t.size = 0
  t.q.init(size)


proc txInsert*(t: var TxGroupAddr; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reassigning from an existing local/remote queue is supported (see
  ## `item.local` flag.)
  let sched = item.local.toGroupSched
  if t.q.hasKey(ethAddr):
    if t.q[ethAddr].itemList[sched].hasKey(item):
      return
    if t.q[ethAddr].itemList[not sched].delete(item).isOK:
      t.size.dec # happens with re-assign
  else:
    t.q[ethAddr] = TxGroupItemsRef(
      itemList: [initKeeQu[TxItemRef,TxGroupMark](1),
                 initKeeQu[TxItemRef,TxGroupMark](1)])
  t.q[ethAddr].itemList[sched][item] = 0
  t.size.inc


proc txDelete*(t: var TxGroupAddr; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  let sched = item.local.toGroupSched
  if t.q.hasKey(ethAddr) and t.q[ethAddr].itemList[sched].hasKey(item):
    t.q[ethAddr].itemList[sched].del(item)
    t.size.dec
    if t.q[ethAddr].itemList[true.toGroupSched].len == 0 and
       t.q[ethAddr].itemList[false.toGroupSched].len == 0:
      t.q.del(ethAddr)


proc txVerify*(t: var TxGroupAddr): Result[void,(TxGroupInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  var count = 0

  let rc = t.q.verify
  if rc.isErr:
    return err((txGroupVfyQueue,rc.error[2]))

  for itQ in t.q.nextValues:
    var itGroupLen = 0
    for sched in TxGroupSchedule:
      itGroupLen += itQ.itemList[sched].len
    count += itGroupLen
    if itGroupLen == 0:
      return err((txGroupVfyLeafEmpty, keeQuOk))

    for sched in TxGroupSchedule:
      let rc = itQ.itemList[sched].verify
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

proc len*(t: var TxGroupAddr): auto {.inline.} =
  t.q.len

proc first*(t: var TxGroupAddr): auto
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  t.q.first

proc next*(t: var TxGroupAddr; key: EthAddress): auto
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  t.q.next(key)


proc itemList*(it: TxGroupItemsRef; local: bool):
             var KeeQu[TxItemRef,TxGroupMark] {.inline.} =
  ## Getter
  it.itemList[local.toGroupSched]

proc itemListLen*(it: TxGroupItemsRef; local: bool): int {.inline.} =
  ## Getter
  it.itemList[local.toGroupSched].len

proc itemListLen*(it: TxGroupItemsRef): int {.inline.} =
  ## Getter
  it.itemListLen(true) + it.itemListLen(false)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
