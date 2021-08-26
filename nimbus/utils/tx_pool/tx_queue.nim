# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Queue Structure For Transaction Pool
## ====================================
##
## Ackn: Vaguely inspired by the *txLookup* maps from
## `tx_pool.go <https://github.com/ethereum/go-ethereum/blob/887902ea4d7ee77118ce803e05085bd9055aa46d/core/tx_pool.go#L1646>`_
##

import
  std/[tables],
  ../rnd_qu,
  ./tx_item,
  eth/common,
  stew/results

type
  TxQueueSchedule* = enum ##\
    ## Sub-queues
    TxLocalQueue = 0
    TxRemoteQueue = 1

  TxQueueItemRef* = ##\
    ## Queue handler wrapper, needed in `first()`, `next()`, etc.
    RndQuItemRef[Hash256,TxItemRef]

  TxQueueRef* = ref object ##\
    ## Chronological queue and ID table, fifo
    q: array[TxQueueSchedule, RndQuRef[Hash256,TxItemRef]]

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc `not`(sched: TxQueueSchedule): TxQueueSchedule {.inline.} =
  if sched == TxLocalQueue: TxRemoteQueue else: TxLocalQueue

# ------------------------------------------------------------------------------
# Public all-queue helpers
# ------------------------------------------------------------------------------

proc newQueueRef*(): TxQueueRef =
  TxQueueRef(
    q: [newRndQu[Hash256,TxItemRef](),
        newRndQu[Hash256,TxItemRef]()])

proc txAppend*(aq: TxQueueRef;
               key: Hash256; sched: TxQueueSchedule; item: TxItemRef)
    {.gcsafe,raises: [Defect,KeyError].} =
  ## Reassigning from an existing local/remote queue is supported
  aq.q[sched][key] = item
  aq.q[not sched].del(key)

proc txDelete*(ap: TxQueueRef;
               key: Hash256; sched: TxQueueSchedule): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  let rc = ap.q[sched].delete(key)
  if rc.isOK:
    return ok(rc.value.data)
  err()

proc txVerify*(aq: TxQueueRef): Result[void,RndQuInfo]
    {.gcsafe,raises: [Defect,KeyError].} =
  for sched in TxQueueSchedule:
    let rc = aq.q[sched].verify
    if rc.isErr:
      return err(rc.error[2])
  ok()

# ------------------------------------------------------------------------------
# Public fetch & traversal
# ------------------------------------------------------------------------------

proc hasKey*(aq: TxQueueRef; key: Hash256; sched: TxQueueSchedule): bool =
  aq.q[sched].hasKey(key)

proc eq*(aq: TxQueueRef;
         key: Hash256; sched: TxQueueSchedule): Result[TxItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  if aq.q[sched].hasKey(key):
    return ok(aq.q[sched][key])
  err()

proc first*(aq: TxQueueRef;
            sched: TxQueueSchedule): Result[TxQueueItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].first

proc next*(aq: TxQueueRef;
           sched: TxQueueSchedule; item: TxQueueItemRef):
             Result[TxQueueItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].next(item)

proc prev*(aq: TxQueueRef;
           sched: TxQueueSchedule; item: TxQueueItemRef):
             Result[TxQueueItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].prev(item)

proc last*(aq: TxQueueRef;
           sched: TxQueueSchedule): Result[TxQueueItemRef,void]
    {.gcsafe,raises: [Defect,KeyError].} =
  aq.q[sched].last

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc len*(aq: TxQueueRef; sched: TxQueueSchedule): int {.inline.} =
  ## Number of local or remote entries
  aq.q[sched].len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
