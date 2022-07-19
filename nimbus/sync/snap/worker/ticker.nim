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
  eth/[common/eth_types, p2p],
  stint,
  "../.."/[timer_helper, types],
  ./worker_desc

{.push raises: [Defect].}

logScope:
  topics = "snap-ticker"

type
  TickerStats* = object
    accounts*: (float,float)   ## mean and standard deviation
    fillFactor*: (float,float) ## mean and standard deviation
    activeQueues*: int
    flushedQueues*: int64

  TickerStatsUpdater* =
    proc(ns: Worker): TickerStats {.gcsafe, raises: [Defect].}

  TickerEx = ref object of WorkerTickerBase
    ## Account fetching state that is shared among all peers.
    ns:           Worker
    peersActive:  int
    statsCb:      TickerStatsUpdater
    logTicker:    TimerCallback
    tick:         uint64 # more than 5*10^11y before wrap when ticking every sec

const
  defaultTickerStartDelay = 100.milliseconds
  tickerLogInterval = 1.seconds

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

template noFmtError(info: static[string]; code: untyped) =
  try:
    code
  except ValueError as e:
    raiseAssert "Inconveivable (" & info & "): " & e.msg

proc setLogTicker(sf: TickerEx; at: Moment) {.gcsafe.}

proc runLogTicker(sf: TickerEx) {.gcsafe.} =
  var
    avAccounts = ""
    avUtilisation = ""
  let
    tick = sf.tick.toSI
    peers = sf.peersActive

    y = sf.statsCb(sf.ns)
    queues = y.activeQueues
    flushed = y.flushedQueues
    mem = getTotalMem().uint.toSI

  noFmtError("runLogTicker"):
    avAccounts = (&"{(y.accounts[0]+0.5).int64}({(y.accounts[1]+0.5).int64})")
    avUtilisation = &"{y.fillFactor[0]*100.0:.2f}%({y.fillFactor[1]*100.0:.2f}%)"

  info "Sync queue average statistics",
    tick, peers, queues, avAccounts, avUtilisation, flushed, mem

  sf.tick.inc
  sf.setLogTicker(Moment.fromNow(tickerLogInterval))

proc setLogTicker(sf: TickerEx; at: Moment) =
  if sf.logTicker.isNil:
    debug "Sync accounts progress ticker has stopped"
  else:
    sf.logTicker = safeSetTimer(at, runLogTicker, sf)

# ------------------------------------------------------------------------------
# Private getters/setters
# ------------------------------------------------------------------------------

proc tickerEx(ns: Worker): TickerEx =
  ## Handy helper
  ns.tickerBase.TickerEx

proc `tickerEx=`(ns: Worker; value: TickerEx) =
  ## Handy helper
  ns.tickerBase = value

# ------------------------------------------------------------------------------
# Public start/stop functions!
# ------------------------------------------------------------------------------

proc tickerSetup*(ns: Worker; cb: TickerStatsUpdater) =
  ## Global set up
  if ns.tickerEx.isNil:
    ns.tickerEx = TickerEx(ns: ns)
  ns.tickerEx.statsCb = cb

proc tickerRelease*(ns: Worker) =
  ## Global clean up
  if not ns.tickerEx.isNil:
    ns.tickerEx.logTicker = nil # stop timer
    ns.tickerEx = nil           # unlink `TickerEx` object

proc tickerStart*(ns: Worker) =
  ## Re/start ticker unconditionally
  ns.tickerEx.tick = 0
  ns.tickerEx.logTicker = safeSetTimer(
    Moment.fromNow(defaultTickerStartDelay),
    runLogTicker,
    ns.tickerEx)

proc tickerStop*(ns: Worker) =
  ## Stop ticker unconditionally
  ns.tickerEx.logTicker = nil

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc tickerStartPeer*(sp: WorkerBuddy) =
  if sp.ns.tickerEx.peersActive <= 0:
    sp.ns.tickerEx.peersActive = 1
    sp.ns.tickerStart()
  else:
    sp.ns.tickerEx.peersActive.inc

proc tickerStopPeer*(sp: WorkerBuddy) =
  sp.ns.tickerEx.peersActive.dec
  if sp.ns.tickerEx.peersActive <= 0:
    sp.ns.tickerStop()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
