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
    txGroupVfyLeafEmpty ## Empty leaf list
    txGroupVfyLeafQueue ## Corrupted leaf list
    txGroupVfySize      ## Size count mismatch

  TxGroupMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxGroupItems* = ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    KeeQu[TxItemRef,TxGroupMark]

  TxGroupAddr* = object ##\
    ## Per address table
    size: int
    q: Table[EthAddress,TxGroupItems]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(t: var TxGroupAddr; size = 10) =
  ## Optional constructor
  t.size = 0
  t.q = initTable[EthAddress,TxGroupItems](size.nextPowerOfTwo)


proc txInsert*(t: var TxGroupAddr; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  if not t.q.hasKey(ethAddr):
    t.q[ethAddr] = initKeeQu[TxItemRef,TxGroupMark](1)
  elif t.q[ethAddr].hasKey(item):
    return
  t.q[ethAddr][item] = 0
  t.size.inc


proc txDelete*(t: var TxGroupAddr; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  if t.q.hasKey(ethAddr) and t.q[ethAddr].hasKey(item):
    t.q[ethAddr].del(item)
    t.size.dec
    if t.q[ethAddr].len == 0:
      t.q.del(ethAddr)


proc txVerify*(t: var TxGroupAddr): Result[void,(TxGroupInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  var count = 0

  for (ethAddr,itQ) in t.q.mpairs:
    count += itQ.len
    if itQ.len == 0:
      return err((txGroupVfyLeafEmpty, keeQuOk))

    let rc = itQ.verify
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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
