# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[strformat, strutils],
  pkg/[chronos, chronicles, eth/common, stint],
  ../../../../utils/prettify,
  ../../../types

logScope:
  topics = "ticker"

type
  TickerFlareStatsUpdater* = proc: TickerFlareStats {.gcsafe, raises: [].}
    ## Full sync state update function

  TickerFlareStats* = object
    ## Full sync state (see `TickerFullStatsUpdater`)
    base*: BlockNumber
    least*: BlockNumber
    final*: BlockNumber
    beacon*: BlockNumber
    unprocTop*: BlockNumber
    nUnprocessed*: uint64
    nUnprocFragm*: int
    nStaged*: int
    stagedTop*: BlockNumber
    reorg*: int

  TickerRef* = ref object
    ## Ticker descriptor object
    nBuddies: int
    started: Moment
    visited: Moment
    prettyPrint: proc(t: TickerRef) {.gcsafe, raises: [].}
    flareCb: TickerFlareStatsUpdater
    lastStats: TickerFlareStats

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

  tickerStartDelay = chronos.milliseconds(100)
  tickerLogInterval = chronos.seconds(1)
  tickerLogSuppressMax = chronos.seconds(100)

  logTxt0 = "Flare ticker"

# ------------------------------------------------------------------------------
# Private functions: pretty printing
# ------------------------------------------------------------------------------

proc pc99(val: float): string =
  if 0.99 <= val and val < 1.0: "99%"
  elif 0.0 < val and val <= 0.01: "1%"
  else: val.toPC(0)

proc toStr(a: Opt[int]): string =
  if a.isNone: "n/a"
  else: $a.unsafeGet

# ------------------------------------------------------------------------------
# Private functions: printing ticker messages
# ------------------------------------------------------------------------------

when extraTraceMessages:
  template logTxt(info: static[string]): static[string] =
    logTxt0 & " " & info

proc flareTicker(t: TickerRef) {.gcsafe.} =
  let
    data = t.flareCb()
    now = Moment.now()

  if data != t.lastStats or
     tickerLogSuppressMax < (now - t.visited):
    let
      B = data.base.toStr
      L = data.least.toStr
      F = data.final.toStr
      Z = data.beacon.toStr
      staged = if data.nStaged == 0: "n/a"
               else: data.stagedTop.toStr & "(" & $data.nStaged & ")"
      unproc = if data.nUnprocFragm == 0: "n/a"
               else: data.unprocTop.toStr & "(" &
                     data.nUnprocessed.toSI & "," & $data.nUnprocFragm & ")"
      reorg = data.reorg
      peers = t.nBuddies

      # With `int64`, there are more than 29*10^10 years range for seconds
      up = (now - t.started).seconds.uint64.toSI
      mem = getTotalMem().uint.toSI

    t.lastStats = data
    t.visited = now

    info logTxt0, up, peers, B, L, F, Z, staged, unproc, reorg, mem

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

proc setLogTicker(t: TickerRef; at: Moment) {.gcsafe.}

proc runLogTicker(t: TickerRef) {.gcsafe.} =
  t.prettyPrint(t)
  t.setLogTicker(Moment.fromNow(tickerLogInterval))

proc setLogTicker(t: TickerRef; at: Moment) =
  if t.flareCb.isNil:
    when extraTraceMessages:
      debug logTxt "was stopped", nBuddies=t.nBuddies
  else:
    # Store the `runLogTicker()` in a closure to avoid some garbage collection
    # memory corruption issues that might occur otherwise.
    discard setTimer(at, proc(ign: pointer) = runLogTicker(t))

# ------------------------------------------------------------------------------
# Public constructor and start/stop functions
# ------------------------------------------------------------------------------

proc init*(T: type TickerRef; cb: TickerFlareStatsUpdater): T =
  ## Constructor
  result = TickerRef(
    prettyPrint: flareTicker,
    flareCb:     cb,
    started:     Moment.now())
  result.setLogTicker Moment.fromNow(tickerStartDelay)

proc destroy*(t: TickerRef) =
  ## Stop ticker unconditionally
  if not t.isNil:
    t.flareCb = TickerFlareStatsUpdater(nil)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc startBuddy*(t: TickerRef) =
  ## Increment buddies counter and start ticker unless running.
  if not t.isNil:
    if t.nBuddies <= 0:
      t.nBuddies = 1
    else:
      t.nBuddies.inc
    when extraTraceMessages:
      debug logTxt "start buddy", nBuddies=t.nBuddies

proc stopBuddy*(t: TickerRef) =
  ## Decrement buddies counter and stop ticker if there are no more registered
  ## buddies.
  if not t.isNil:
    if 0 < t.nBuddies:
      t.nBuddies.dec
    when extraTraceMessages:
      debug logTxt "stop buddy", nBuddies=t.nBuddies

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
