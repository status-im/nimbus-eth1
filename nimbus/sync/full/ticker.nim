# Nimbus - Fetch account and storage states from peers efficiently
#
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
  eth/[common/eth_types, p2p],
  stint,
  ".."/[timer_helper, types]

{.push raises: [Defect].}

logScope:
  topics = "full-ticker"

type
  TickerStats* = object
    topPersistent*: BlockNumber
    nextUnprocessed*: Option[BlockNumber]
    nextStaged*: Option[BlockNumber]
    nStagedQueue*: int
    reOrg*: bool

  TickerStatsUpdater* =
    proc: TickerStats {.gcsafe, raises: [Defect].}

  Ticker* = ref object
    nBuddies:  int
    lastStats: TickerStats
    lastTick:  uint64
    statsCb:   TickerStatsUpdater
    logTicker: TimerCallback
    tick:      uint64 # more than 5*10^11y before wrap when ticking every sec

const
  tickerStartDelay = 100.milliseconds
  tickerLogInterval = 1.seconds
  tickerLogSuppressMax = 100

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

proc pp(n: BlockNumber): string =
  "#" & $n

proc pp(n: Option[BlockNumber]): string =
  if n.isNone: "n/a" else: n.get.pp

proc setLogTicker(t: Ticker; at: Moment) {.gcsafe.}

proc runLogTicker(t: Ticker) {.gcsafe.} =
  let data = t.statsCb()

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

    info "Sync statistics", tick, buddies,
      persistent, unprocessed, staged, queued, reOrg, mem

  t.tick.inc
  t.setLogTicker(Moment.fromNow(tickerLogInterval))


proc setLogTicker(t: Ticker; at: Moment) =
  if not t.logTicker.isNil:
    t.logTicker = safeSetTimer(at, runLogTicker, t)

# ------------------------------------------------------------------------------
# Public constructor and start/stop functions
# ------------------------------------------------------------------------------

proc init*(T: type Ticker; cb: TickerStatsUpdater): T =
  ## Constructor
  T(statsCb: cb)

proc start*(t: Ticker) =
  ## Re/start ticker unconditionally
  #debug "Started ticker"
  t.logTicker = safeSetTimer(Moment.fromNow(tickerStartDelay), runLogTicker, t)

proc stop*(t: Ticker) =
  ## Stop ticker unconditionally
  t.logTicker = nil
  #debug "Stopped ticker"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc startBuddy*(t: Ticker) =
  ## Increment buddies counter and start ticker unless running.
  if t.nBuddies <= 0:
    t.nBuddies = 1
    t.start()
  else:
    t.nBuddies.inc

proc stopBuddy*(t: Ticker) =
  ## Decrement buddies counter and stop ticker if there are no more registered
  ## buddies.
  t.nBuddies.dec
  if t.nBuddies <= 0:
    t.stop()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
