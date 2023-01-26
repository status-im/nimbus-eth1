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
  std/[strformat, strutils],
  chronos,
  chronicles,
  eth/[common, p2p],
  stint,
  ../../../utils/prettify,
  ../../misc/timer_helper

{.push raises: [Defect].}

logScope:
  topics = "snap-tick"

type
  # TODO: Seems like a compiler name mangling bug or so. If this is named
  # `TickerStats` then `eqeq___syncZsnapZworkerZticker_97` complains
  # that the TickerStats object does not have beaconBlock and pivotBlock
  # members. So I'm assuming here it seems to take the wrong function, meaning
  # the one of the `TickerStats` of full sync, because it has the same name and
  # the same module name. Not sure..
  SnapTickerStats* = object
    beaconBlock*: Option[BlockNumber]
    pivotBlock*: Option[BlockNumber]
    nAccounts*: (float,float)          ## Mean and standard deviation
    accountsFill*: (float,float,float) ## Mean, standard deviation, merged total
    nAccountStats*: int                ## #chunks
    nSlotLists*: (float,float)         ## Mean and standard deviation
    nStorageQueue*: Option[int]
    nQueues*: int

  TickerStatsUpdater* =
    proc: SnapTickerStats {.gcsafe, raises: [Defect].}

  TickerRef* = ref object
    ## Account fetching state that is shared among all peers.
    nBuddies:  int
    recovery:  bool
    lastRecov: bool
    lastStats: SnapTickerStats
    statsCb:   TickerStatsUpdater
    logTicker: TimerCallback
    started:   Moment
    visited:   Moment

const
  tickerStartDelay = chronos.milliseconds(100)
  tickerLogInterval = chronos.seconds(1)
  tickerLogSuppressMax = chronos.seconds(100)

# ------------------------------------------------------------------------------
# Private functions: pretty printing
# ------------------------------------------------------------------------------

# proc ppMs*(elapsed: times.Duration): string
#     {.gcsafe, raises: [Defect, ValueError]} =
#   result = $elapsed.inMilliseconds
#   let ns = elapsed.inNanoseconds mod 1_000_000 # fraction of a milli second
#   if ns != 0:
#     # to rounded deca milli seconds
#     let dm = (ns + 5_000i64) div 10_000i64
#     result &= &".{dm:02}"
#   result &= "ms"
#
# proc ppSecs*(elapsed: times.Duration): string
#     {.gcsafe, raises: [Defect, ValueError]} =
#   result = $elapsed.inSeconds
#   let ns = elapsed.inNanoseconds mod 1_000_000_000 # fraction of a second
#   if ns != 0:
#     # round up
#     let ds = (ns + 5_000_000i64) div 10_000_000i64
#     result &= &".{ds:02}"
#   result &= "s"
#
# proc ppMins*(elapsed: times.Duration): string
#     {.gcsafe, raises: [Defect, ValueError]} =
#   result = $elapsed.inMinutes
#   let ns = elapsed.inNanoseconds mod 60_000_000_000 # fraction of a minute
#   if ns != 0:
#     # round up
#     let dm = (ns + 500_000_000i64) div 1_000_000_000i64
#     result &= &":{dm:02}"
#   result &= "m"
#
# proc pp(d: times.Duration): string
#     {.gcsafe, raises: [Defect, ValueError]} =
#   if 40 < d.inSeconds:
#     d.ppMins
#   elif 200 < d.inMilliseconds:
#     d.ppSecs
#   else:
#     d.ppMs

proc pc99(val: float): string =
  if 0.99 <= val and val < 1.0: "99%"
  elif 0.0 < val and val <= 0.01: "1%"
  else: val.toPC(0)

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
  let
    data = t.statsCb()
    now = Moment.now()

  if data != t.lastStats or
     t.recovery != t.lastRecov or
     tickerLogSuppressMax < (now - t.visited):
    var
      nAcc, nSto, bulk: string
      pv = "n/a"
      bc = "n/a"
      nStoQue = "n/a"
    let
      recoveryDone = t.lastRecov
      accCov = data.accountsFill[0].pc99 &
         "(" & data.accountsFill[1].pc99 & ")" &
         "/" & data.accountsFill[2].pc99 &
         "~" & data.nAccountStats.uint.toSI
      nInst = t.nBuddies

      # With `int64`, there are more than 29*10^10 years range for seconds
      up = (now - t.started).seconds.uint64.toSI
      mem = getTotalMem().uint.toSI

    t.lastStats = data
    t.visited = now
    t.lastRecov = t.recovery

    noFmtError("runLogTicker"):
      if data.pivotBlock.isSome:
        pv = &"#{data.pivotBlock.get}/{data.nQueues}"
      if data.beaconBlock.isSome:
        bc = &"#{data.beaconBlock.get}"
      nAcc = (&"{(data.nAccounts[0]+0.5).int64}" &
              &"({(data.nAccounts[1]+0.5).int64})")
      nSto = (&"{(data.nSlotLists[0]+0.5).int64}" &
              &"({(data.nSlotLists[1]+0.5).int64})")

    if data.nStorageQueue.isSome:
      nStoQue = $data.nStorageQueue.unsafeGet

    if t.recovery:
      info "Snap sync statistics (recovery)",
        up, nInst, bc, pv, nAcc, accCov, nSto, nStoQue, mem
    elif recoveryDone:
      info "Snap sync statistics (recovery done)",
        up, nInst, bc, pv, nAcc, accCov, nSto, nStoQue, mem
    else:
      info "Snap sync statistics",
        up, nInst, bc, pv, nAcc, accCov, nSto, nStoQue, mem

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
  if t.started == Moment.default:
    t.started = Moment.now()

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
    if not t.recovery:
      t.start()
  else:
    t.nBuddies.inc

proc startRecovery*(t: TickerRef) =
  ## Ditto for recovery mode
  if not t.recovery:
    t.recovery = true
    if t.nBuddies <= 0:
      t.start()

proc stopBuddy*(t: TickerRef) =
  ## Decrement buddies counter and stop ticker if there are no more registered
  ## buddies.
  t.nBuddies.dec
  if t.nBuddies <= 0 and not t.recovery:
    t.stop()

proc stopRecovery*(t: TickerRef) =
  ## Ditto for recovery mode
  if t.recovery:
    t.recovery = false
    t.stop()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
