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
  ../../types,
  "."/[timer_helper, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap-ticker"

type
  TickerStats* = object
    activeQueues*: uint
    totalQueues*: uint64
    avFillFactor*: float

  TickerStatsUpdater* =
    proc(ns: Worker): TickerStats {.gcsafe, raises: [Defect].}

  AccountsStats = object
    counted: int64
    bytes: int64

  TickerEx = ref object of WorkerTickerBase
    ## Account fetching state that is shared among all peers.
    ns:           Worker
    accounts:     AccountsStats
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

proc setLogTicker(sf: TickerEx; at: Moment) {.gcsafe.}

proc runLogTicker(sf: TickerEx) {.gcsafe.} =
  let
    y = sf.statsCb(sf.ns)
    fill = if 0 < y.activeQueues: y.avFillFactor/y.activeQueues.float else: 0.0
    utilisation = fill.toPC(rounding = 0)

  info "Sync accounts progress",
    tick = sf.tick.toSI,
    peers = sf.peersActive,
    accounts = sf.accounts.counted,
    states = y.totalQueues,
    queues = y.activeQueues,
    utilisation

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

proc tickerCountAccounts*(sp: WorkerBuddy; bytes: SomeInteger; nAcc = 1) =
  sp.ns.tickerEx.accounts.counted += nAcc
  sp.ns.tickerEx.accounts.bytes += bytes

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
