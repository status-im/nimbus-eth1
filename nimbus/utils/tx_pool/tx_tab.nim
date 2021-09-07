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
  std/[hashes, tables],
  ../keequ,
  ./tx_item,
  eth/[common],
  stew/results

type
  TxTabInfo* = enum
    txTabOk = 0
    txTabVfyLeafEmpty ## Empty leaf list
    txTabVfyLeafQueue ## Corrupted leaf list
    txTabVfySize      ## Size count mismatch

  TxTabMark* = ##\
    ## Ready to be used for something, currently just a blind value that\
    ## comes in when queuing items for the same key (e.g. gas price.)
    int

  TxTabItems* = ##\
    ## Chronologically ordered queue/fifo with random access. This is\
    ## typically used when queuing items for the same key (e.g. gas price.)
    KeeQu[TxItemRef,TxTabMark]

  TxAddrTab* = object ##\
    ## Per address table
    size: int
    q: Table[EthAddress,TxTabItems]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc hash(itemRef: TxItemRef): Hash =
  ## Needed for the `TxListItems` underlying table
  cast[pointer](itemRef).hash

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc txInit*(t: var TxAddrTab; size = 10) =
  t.size = 0
  t.q = initTable[EthAddress,TxTabItems](size)


proc txInsert*(t: var TxAddrTab; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  if not t.q.hasKey(ethAddr):
    t.q[ethAddr] = initKeeQu[TxItemRef,TxTabMark](1)
  elif t.q[ethAddr].hasKey(item):
    return
  t.q[ethAddr][item] = 0
  t.size.inc


proc txDelete*(t: var TxAddrTab; ethAddr: EthAddress; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  if t.q.hasKey(ethAddr) and t.q[ethAddr].hasKey(item):
    t.q[ethAddr].del(item)
    t.size.dec
    if t.q[ethAddr].len == 0:
      t.q.del(ethAddr)


proc txVerify*(t: var TxAddrTab): Result[void,(TxTabInfo,KeeQuInfo)]
    {.gcsafe,raises: [Defect,KeyError].} =
  var count = 0

  for (ethAddr,itQ) in t.q.mpairs:
    count += itQ.len
    if itQ.len == 0:
      return err((txTabVfyLeafEmpty, keeQuOk))

    let rc = itQ.verify
    if rc.isErr:
      return err((txTabVfyLeafQueue, rc.error[2]))

  if count != t.size:
    return err((txTabVfySize, keeQuOk))
  ok()


proc nLeaves*(t: var TxAddrTab): int {.inline.} =
  t.size


# Table ops
proc`[]`*(t: var TxAddrTab; key: EthAddress): auto
    {.inline,gcsafe,raises: [Defect,KeyError].} =
  t.q[key]

proc hasKey*(t: var TxAddrTab; key: EthAddress): auto {.inline.} =
  t.q.hasKey(key)

proc len*(t: var TxAddrTab): auto {.inline.} =
  t.q.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
