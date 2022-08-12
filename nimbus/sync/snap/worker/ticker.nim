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
  std/[sequtils, strformat, strutils, times],
  chronos,
  chronicles,
  eth/[common/eth_types, p2p],
  stint,
  ../../../utils/prettify,
  ../../timer_helper,
  ./accounts_db

{.push raises: [Defect].}

logScope:
  topics = "snap-ticker"

type
  TickerStats* = object
    pivotBlock*: Option[BlockNumber]
    accounts*: (float,float)   ## mean and standard deviation
    fillFactor*: (float,float) ## mean and standard deviation
    activeQueues*: int
    flushedQueues*: int64
    bulkStore*: AccountLoadStats

  TickerStatsUpdater* =
    proc: TickerStats {.gcsafe, raises: [Defect].}

  TickerRef* = ref object
    ## Account fetching state that is shared among all peers.
    nBuddies:  int
    lastStats: TickerStats
    lastTick:  uint64
    statsCb:   TickerStatsUpdater
    logTicker: TimerCallback
    tick:      uint64 # more than 5*10^11y before wrap when ticking every sec

const
  tickerStartDelay = chronos.milliseconds(100)
  tickerLogInterval = chronos.seconds(1)
  tickerLogSuppressMax = 100

# ------------------------------------------------------------------------------
# Private functions: pretty printing
# ------------------------------------------------------------------------------

proc ppMs*(elapsed: times.Duration): string
    {.gcsafe, raises: [Defect, ValueError]} =
  result = $elapsed.inMilliseconds
  let ns = elapsed.inNanoseconds mod 1_000_000 # fraction of a milli second
  if ns != 0:
    # to rounded deca milli seconds
    let dm = (ns + 5_000i64) div 10_000i64
    result &= &".{dm:02}"
  result &= "ms"

proc ppSecs*(elapsed: times.Duration): string
    {.gcsafe, raises: [Defect, ValueError]} =
  result = $elapsed.inSeconds
  let ns = elapsed.inNanoseconds mod 1_000_000_000 # fraction of a second
  if ns != 0:
    # round up
    let ds = (ns + 5_000_000i64) div 10_000_000i64
    result &= &".{ds:02}"
  result &= "s"

proc ppMins*(elapsed: times.Duration): string
    {.gcsafe, raises: [Defect, ValueError]} =
  result = $elapsed.inMinutes
  let ns = elapsed.inNanoseconds mod 60_000_000_000 # fraction of a minute
  if ns != 0:
    # round up
    let dm = (ns + 500_000_000i64) div 1_000_000_000i64
    result &= &":{dm:02}"
  result &= "m"

proc pp(d: times.Duration): string
    {.gcsafe, raises: [Defect, ValueError]} =
  if 40 < d.inSeconds:
    d.ppMins
  elif 200 < d.inMilliseconds:
    d.ppSecs
  else:
    d.ppMs

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

template noFmtError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg

proc setLogTicker(t: TickerRef; at: Moment) {.gcsafe.}

proc runLogTicker(t: TickerRef) {.gcsafe.} =
  let data = t.statsCb()

  if data != t.lastStats or
     t.lastTick + tickerLogSuppressMax < t.tick:
    t.lastStats = data
    t.lastTick = t.tick
    var
      avAccounts = ""
      avUtilisation = ""
      pivot = "n/a"
      bulker = ""
    let
      flushed = data.flushedQueues

      buddies = t.nBuddies
      tick = t.tick.toSI
      mem = getTotalMem().uint.toSI

    noFmtError("runLogTicker"):
      if data.pivotBlock.isSome:
        pivot = &"#{data.pivotBlock.get}({data.activeQueues})"
      avAccounts =
        &"{(data.accounts[0]+0.5).int64}({(data.accounts[1]+0.5).int64})"
      avUtilisation =
        &"{data.fillFactor[0]*100.0:.2f}%({data.fillFactor[1]*100.0:.2f}%)"
      bulker =
        "[" & data.bulkStore.size.toSeq.mapIt(it.toSI).join(",") & "," &
              data.bulkStore.dura.toSeq.mapIt(it.pp).join(",") & "]"

    info "Snap sync statistics",
      tick, buddies, pivot, avAccounts, avUtilisation, flushed, bulker, mem

  t.tick.inc
  t.setLogTicker(Moment.fromNow(tickerLogInterval))


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
