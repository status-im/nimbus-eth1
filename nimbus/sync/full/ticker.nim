# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  chronos,
  chronicles,
  eth/[common, p2p],
  stint,
  ../../utils/prettify,
  ../misc/timer_helper

{.push raises: [].}

logScope:
  topics = "full-ticker"

type
  TickerStats* = object
    topPersistent*: BlockNumber
    nextUnprocessed*: Option[BlockNumber]
    nextStaged*: Option[BlockNumber]
    nStagedQueue*: int
    suspended*: bool
    reOrg*: bool

  TickerStatsUpdater* =
    proc: TickerStats {.gcsafe, raises: [].}

  TickerRef* = ref object
    nBuddies:  int
    lastStats: TickerStats
    lastTick:  uint64
    statsCb:   TickerStatsUpdater
    logTicker: TimerCallback
    tick:      uint64 # more than 5*10^11y before wrap when ticking every sec

const
  tickerStartDelay = 100.milliseconds
  tickerLogInterval = 100.milliseconds # 1.seconds
  tickerLogSuppressMax = 100

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

proc pp(n: BlockNumber): string =
  "#" & $n

proc pp(n: Option[BlockNumber]): string =
  if n.isNone: "n/a" else: n.get.pp

proc setLogTicker(t: TickerRef; at: Moment) {.gcsafe.}

proc runLogTicker(t: TickerRef) {.gcsafe.} =
  GC_fullCollect()
  let data = t.statsCb()
  GC_fullCollect()

  if data != t.lastStats or
     t.lastTick + tickerLogSuppressMax < t.tick:
    t.lastStats = data
    t.lastTick = t.tick
    let
      persistent = data.topPersistent.pp
      staged = data.nextStaged.pp
      unprocessed = data.nextUnprocessed.pp
      queued = data.nStagedQueue
      reOrg = if data.reOrg: "t" else: "f"

      buddies = t.nBuddies
      tick = t.tick.toSI
      mem = getTotalMem().uint.toSI

    if data.suspended:
     info "Sync statistics (suspended)", tick, buddies,
       persistent, unprocessed, staged, queued, reOrg, mem
    else:
     info "Sync statistics", tick, buddies,
       persistent, unprocessed, staged, queued, reOrg, mem

  t.tick.inc
  GC_fullCollect()
  t.setLogTicker(Moment.fromNow(tickerLogInterval))
  GC_fullCollect()


proc setLogTicker(t: TickerRef; at: Moment) =
  if not t.logTicker.isNil:
    t.logTicker = safeSetTimer(at, runLogTicker, t)

# ------------------------------------------------------------------------------
# Public constructor and start/stop functions
# ------------------------------------------------------------------------------

proc init*(T: type TickerRef; cb: TickerStatsUpdater): T =
  ## Constructor
  T(statsCb: cb)

proc start*(t: TickerRef) =
  ## Re/start ticker unconditionally
  #debug "Started ticker"
  t.logTicker = safeSetTimer(Moment.fromNow(tickerStartDelay), runLogTicker, t)

proc stop*(t: TickerRef) =
  ## Stop ticker unconditionally
  t.logTicker = nil
  #debug "Stopped ticker"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc startBuddy*(t: TickerRef) =
  ## Increment buddies counter and start ticker unless running.
  if t.nBuddies <= 0:
    t.nBuddies = 1
    t.start()
  else:
    t.nBuddies.inc

proc stopBuddy*(t: TickerRef) =
  ## Decrement buddies counter and stop ticker if there are no more registered
  ## buddies.
  t.nBuddies.dec
  if t.nBuddies <= 0:
    t.stop()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
