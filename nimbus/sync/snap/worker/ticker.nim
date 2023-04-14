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

{.push raises: [].}

import
  std/[options, strformat, strutils],
  chronos,
  chronicles,
  eth/[common, p2p],
  stint,
  ../../../utils/prettify,
  ../../misc/timer_helper,
  ../../types

logScope:
  topics = "snap-tick"

type
  TickerSnapStatsUpdater* = proc: TickerSnapStats {.gcsafe, raises: [].}
    ## Snap sync state update function

  TickerFullStatsUpdater* = proc: TickerFullStats {.gcsafe, raises: [].}
    ## Full sync state update function

  SnapDescDetails = object
    ## Private state descriptor
    snapCb: TickerSnapStatsUpdater
    recovery: bool
    lastRecov: bool
    lastStats: TickerSnapStats

  FullDescDetails = object
    ## Private state descriptor
    fullCb: TickerFullStatsUpdater
    lastStats: TickerFullStats

  TickerSnapStats* = object
    ## Snap sync state (see `TickerSnapStatsUpdater`)
    beaconBlock*: Option[BlockNumber]
    pivotBlock*: Option[BlockNumber]
    nAccounts*: (float,float)          ## Mean and standard deviation
    accountsFill*: (float,float,float) ## Mean, standard deviation, merged total
    nAccountStats*: int                ## #chunks
    nSlotLists*: (float,float)         ## Mean and standard deviation
    nStorageQueue*: Option[int]
    nQueues*: int

  TickerFullStats* = object
    ## Full sync state (see `TickerFullStatsUpdater`)
    pivotBlock*: Option[BlockNumber]
    topPersistent*: BlockNumber
    nextUnprocessed*: Option[BlockNumber]
    nextStaged*: Option[BlockNumber]
    nStagedQueue*: int
    suspended*: bool
    reOrg*: bool

  TickerRef* = ref object
    ## Ticker descriptor object
    nBuddies: int
    logTicker: TimerCallback
    started: Moment
    visited: Moment
    prettyPrint: proc(t: TickerRef) {.gcsafe, raises: [].}
    case fullMode: bool
    of false:
      snap: SnapDescDetails
    of true:
      full: FullDescDetails

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
# Private functions: printing ticker messages
# ------------------------------------------------------------------------------

template noFmtError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg

proc snapTicker(t: TickerRef) {.gcsafe.} =
  let
    data = t.snap.snapCb()
    now = Moment.now()

  if data != t.snap.lastStats or
     t.snap.recovery != t.snap.lastRecov or
     tickerLogSuppressMax < (now - t.visited):
    var
      nAcc, nSto: string
      pv = "n/a"
      nStoQue = "n/a"
    let
      bc = data.beaconBlock.toStr
      recoveryDone = t.snap.lastRecov
      accCov = data.accountsFill[0].pc99 &
         "(" & data.accountsFill[1].pc99 & ")" &
         "/" & data.accountsFill[2].pc99 &
         "~" & data.nAccountStats.uint.toSI
      nInst = t.nBuddies

      # With `int64`, there are more than 29*10^10 years range for seconds
      up = (now - t.started).seconds.uint64.toSI
      mem = getTotalMem().uint.toSI

    t.snap.lastStats = data
    t.visited = now
    t.snap.lastRecov = t.snap.recovery

    if data.pivotBlock.isSome:
      pv = data.pivotBlock.toStr & "/" & $data.nQueues

    noFmtError("runLogTicker"):
      nAcc = (&"{(data.nAccounts[0]+0.5).int64}" &
              &"({(data.nAccounts[1]+0.5).int64})")
      nSto = (&"{(data.nSlotLists[0]+0.5).int64}" &
              &"({(data.nSlotLists[1]+0.5).int64})")

    if data.nStorageQueue.isSome:
      nStoQue = $data.nStorageQueue.unsafeGet

    if t.snap.recovery:
      info "Snap sync statistics (recovery)",
        up, nInst, bc, pv, nAcc, accCov, nSto, nStoQue, mem
    elif recoveryDone:
      info "Snap sync statistics (recovery done)",
        up, nInst, bc, pv, nAcc, accCov, nSto, nStoQue, mem
    else:
      info "Snap sync statistics",
        up, nInst, bc, pv, nAcc, accCov, nSto, nStoQue, mem


proc fullTicker(t: TickerRef) {.gcsafe.} =
  let
    data = t.full.fullCb()
    now = Moment.now()

  if data != t.full.lastStats or
     tickerLogSuppressMax < (now - t.visited):
    let
      persistent = data.topPersistent.toStr
      staged = data.nextStaged.toStr
      unprocessed = data.nextUnprocessed.toStr
      queued = data.nStagedQueue
      reOrg = if data.reOrg: "t" else: "f"
      pv = data.pivotBlock.toStr

      nInst = t.nBuddies

      # With `int64`, there are more than 29*10^10 years range for seconds
      up = (now - t.started).seconds.uint64.toSI
      mem = getTotalMem().uint.toSI

    t.full.lastStats = data
    t.visited = now

    if data.suspended:
      info "Full sync statistics (suspended)", up, nInst, pv,
        persistent, unprocessed, staged, queued, reOrg, mem
    else:
      info "Full sync statistics", up, nInst, pv,
        persistent, unprocessed, staged, queued, reOrg, mem

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

proc setLogTicker(t: TickerRef; at: Moment) {.gcsafe.}

proc runLogTicker(t: TickerRef) {.gcsafe.} =
  t.prettyPrint(t)
  t.setLogTicker(Moment.fromNow(tickerLogInterval))

proc setLogTicker(t: TickerRef; at: Moment) =
  if not t.logTicker.isNil:
    t.logTicker = safeSetTimer(at, runLogTicker, t)

proc initImpl(t: TickerRef; cb: TickerSnapStatsUpdater) =
  t.fullMode = false
  t.prettyPrint = snapTicker
  t.snap = SnapDescDetails(snapCb: cb)

proc initImpl(t: TickerRef; cb: TickerFullStatsUpdater) =
  t.fullMode = true
  t.prettyPrint = fullTicker
  t.full = FullDescDetails(fullCb: cb)

# ------------------------------------------------------------------------------
# Public constructor and start/stop functions
# ------------------------------------------------------------------------------

proc init*(T: type TickerRef; cb: TickerSnapStatsUpdater): T =
  ## Constructor
  new result
  result.initImpl(cb)

proc init*(t: TickerRef; cb: TickerSnapStatsUpdater) =
  ## Re-initialise ticket
  if not t.isNil:
    t.visited.reset
    if t.fullMode:
      t.prettyPrint(t) # print final state for full sync
    t.initImpl(cb)

proc init*(t: TickerRef; cb: TickerFullStatsUpdater) =
  ## Re-initialise ticket
  if not t.isNil:
    t.visited.reset
    if not t.fullMode:
      t.prettyPrint(t) # print final state for snap sync
    t.initImpl(cb)

proc start*(t: TickerRef) =
  ## Re/start ticker unconditionally
  if not t.isNil:
    #debug "Started ticker"
    t.logTicker = safeSetTimer(Moment.fromNow(tickerStartDelay),runLogTicker,t)
    if t.started == Moment.default:
      t.started = Moment.now()

proc stop*(t: TickerRef) =
  ## Stop ticker unconditionally
  if not t.isNil:
    t.logTicker = nil
    #debug "Stopped ticker"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc startBuddy*(t: TickerRef) =
  ## Increment buddies counter and start ticker unless running.
  if not t.isNil:
    if t.nBuddies <= 0:
      t.nBuddies = 1
      if not t.fullMode:
        if not t.snap.recovery:
          t.start()
    else:
      t.nBuddies.inc

proc startRecovery*(t: TickerRef) =
  ## Ditto for recovery mode
  if not t.isNil:
    if not t.fullMode:
      if not t.snap.recovery:
        t.snap.recovery = true
        if t.nBuddies <= 0:
          t.start()

proc stopBuddy*(t: TickerRef) =
  ## Decrement buddies counter and stop ticker if there are no more registered
  ## buddies.
  if not t.isNil:
    t.nBuddies.dec
    if t.nBuddies <= 0:
      if not t.fullMode:
        if not t.snap.recovery:
          t.stop()

proc stopRecovery*(t: TickerRef) =
  ## Ditto for recovery mode
  if not t.isNil:
    if not t.fullMode:
      if t.snap.recovery:
        t.snap.recovery = false
        t.stop()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
