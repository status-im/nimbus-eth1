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
  std/strutils,
  pkg/[chronos, chronicles, eth/common, stint],
  ../../../../utils/prettify,
  ../helpers

logScope:
  topics = "ticker"

type
  TickerStatsUpdater* = proc: TickerStats {.gcsafe, raises: [].}
    ## Full sync state update function

  TickerStats* = object
    ## Full sync state (see `TickerFullStatsUpdater`)
    base*: BlockNumber
    coupler*: BlockNumber
    dangling*: BlockNumber
    endBn*: BlockNumber
    target*: BlockNumber
    newTargetOk*: bool

    hdrUnprocTop*: BlockNumber
    nHdrUnprocessed*: uint64
    nHdrUnprocFragm*: int
    nHdrStaged*: int
    hdrStagedTop*: BlockNumber

    blkUnprocTop*: BlockNumber
    nBlkUnprocessed*: uint64
    nBlkUnprocFragm*: int
    nBlkStaged*: int
    blkStagedBottom*: BlockNumber

    reorg*: int
    nBuddies*: int

  TickerRef* = ref object
    ## Ticker descriptor object
    started: Moment
    visited: Moment
    prettyPrint: proc(t: TickerRef) {.gcsafe, raises: [].}
    statsCb: TickerStatsUpdater
    lastStats: TickerStats

const
  tickerStartDelay = chronos.milliseconds(100)
  tickerLogInterval = chronos.seconds(1)
  tickerLogSuppressMax = chronos.seconds(100)

# ------------------------------------------------------------------------------
# Private functions: printing ticker messages
# ------------------------------------------------------------------------------

proc tickerLogger(t: TickerRef) {.gcsafe.} =
  let
    data = t.statsCb()
    now = Moment.now()

  if data != t.lastStats or
     tickerLogSuppressMax < (now - t.visited):
    let
      B = if data.base == data.coupler: "C" else: data.base.bnStr
      C = if data.coupler == data.dangling: "D" else: data.coupler.bnStr
      D = if data.dangling == data.endBn: "E" else: data.dangling.bnStr
      E = if data.endBn == data.target: "T" else: data.endBn.bnStr
      T = if data.newTargetOk: "?" & $data.target else: data.target.bnStr

      hS = if data.nHdrStaged == 0: "n/a"
           else: data.hdrStagedTop.bnStr & "(" & $data.nHdrStaged & ")"
      hU = if data.nHdrUnprocFragm == 0: "n/a"
           else: data.hdrUnprocTop.bnStr & "(" &
                 data.nHdrUnprocessed.toSI & "," & $data.nHdrUnprocFragm & ")"

      bS = if data.nBlkStaged == 0: "n/a"
           else: data.blkStagedBottom.bnStr & "(" & $data.nBlkStaged & ")"
      bU = if data.nBlkUnprocFragm == 0: "n/a"
           else: data.blkUnprocTop.bnStr & "(" &
                 data.nBlkUnprocessed.toSI & "," & $data.nBlkUnprocFragm & ")"

      reorg = data.reorg
      peers = data.nBuddies

      # With `int64`, there are more than 29*10^10 years range for seconds
      up = (now - t.started).seconds.uint64.toSI
      mem = getTotalMem().uint.toSI

    t.lastStats = data
    t.visited = now

    info "Sync state", up, peers, B, C, D, E, T, hS, hU, bS, bU, reorg, mem

# ------------------------------------------------------------------------------
# Private functions: ticking log messages
# ------------------------------------------------------------------------------

proc setLogTicker(t: TickerRef; at: Moment) {.gcsafe.}

proc runLogTicker(t: TickerRef) {.gcsafe.} =
  t.prettyPrint(t)
  t.setLogTicker(Moment.fromNow(tickerLogInterval))

proc setLogTicker(t: TickerRef; at: Moment) =
  if t.statsCb.isNil:
    debug "Stopped", nBuddies=t.lastStats.nBuddies
  else:
    # Store the `runLogTicker()` in a closure to avoid some garbage collection
    # memory corruption issues that might occur otherwise.
    discard setTimer(at, proc(ign: pointer) = runLogTicker(t))

# ------------------------------------------------------------------------------
# Public constructor and start/stop functions
# ------------------------------------------------------------------------------

proc init*(T: type TickerRef; cb: TickerStatsUpdater): T =
  ## Constructor
  result = TickerRef(
    prettyPrint: tickerLogger,
    statsCb:     cb,
    started:     Moment.now())
  result.setLogTicker Moment.fromNow(tickerStartDelay)

proc destroy*(t: TickerRef) =
  ## Stop ticker unconditionally
  if not t.isNil:
    t.statsCb = TickerStatsUpdater(nil)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
