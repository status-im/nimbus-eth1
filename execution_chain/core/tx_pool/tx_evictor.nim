# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/times,
  chronicles,
  chronos,
  ./tx_desc

logScope:
  topics = "txpool"

const
  TX_EVICTION_INTERVAL = chronos.minutes(1)

type
  TxEvictorRef* = ref object
    xp: TxPoolRef
    interval: chronos.Duration
    lifeTime: times.Duration
    loopFut: Future[void].Raising([CancelledError])

# ------------------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------------------

proc init*(
    T: type TxEvictorRef,
    xp: TxPoolRef,
    interval = TX_EVICTION_INTERVAL,
    lifeTime = TX_ITEM_LIFETIME,
): T =
  T(xp: xp, interval: interval, lifeTime: lifeTime)

proc evictLoop(ev: TxEvictorRef) {.async: (raises: [CancelledError]).} =
  while true:
    await sleepAsync(ev.interval)
    let lenBefore = ev.xp.len
    ev.xp.removeExpiredTxs(ev.lifeTime)
    let evicted = lenBefore - ev.xp.len
    if evicted > 0:
      debug "Evicted expired transactions from txpool",
        evicted = evicted,
        remaining = ev.xp.len

proc start*(ev: TxEvictorRef) =
  ev.loopFut = ev.evictLoop()

proc stop*(ev: TxEvictorRef) {.async: (raises: []).} =
  if not ev.loopFut.isNil:
    await ev.loopFut.cancelAndWait()
