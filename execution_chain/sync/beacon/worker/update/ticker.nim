# Nimbus - Fetch account and storage states from peers efficiently
#
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronos, chronicles, eth/common],
  ../../worker_desc

when enableTicker:
  import
    std/strutils,
    pkg/[stint, stew/interval_set],
    ../headers_staged/staged_queue,
    ../blocks_staged/staged_queue,
    ../helpers,
    ../[blocks_unproc, headers_unproc]

logScope:
  topics = "beacon ticker"

type
  TickerStats = object
    ## Full sync state (see `TickerFullStatsUpdater`)
    base: BlockNumber
    latest: BlockNumber
    coupler: BlockNumber
    dangling: BlockNumber
    head: BlockNumber
    target: BlockNumber
    activeOk: bool

    hdrUnprocTop: BlockNumber
    nHdrUnprocessed: uint64
    nHdrUnprocFragm: int
    nHdrStaged: int
    hdrStagedTop: BlockNumber

    blkUnprocBottom: BlockNumber
    nBlkUnprocessed: uint64
    nBlkUnprocFragm: int
    nBlkStaged: int
    blkStagedBottom: BlockNumber

    state: SyncLayoutState
    reorg: int
    nBuddies: int

  TickerRef* = ref object of RootRef
    ## Ticker descriptor object
    started: Moment
    visited: Moment
    lastStats: TickerStats

# ------------------------------------------------------------------------------
# Private functions: printing ticker messages
# ------------------------------------------------------------------------------

when enableTicker:
  const
    tickerLogInterval = chronos.seconds(5)
    tickerLogSuppressMax = chronos.seconds(100)

  proc updater(ctx: BeaconCtxRef): TickerStats =
    ## Legacy stuff, will be probably be superseded by `metrics`
    TickerStats(
      base:            ctx.chain.baseNumber(),
      latest:          ctx.chain.latestNumber(),
      coupler:         ctx.headersUnprocTotalBottom(),
      dangling:        ctx.dangling.number,
      head:            ctx.head.number,
      target:          ctx.consHeadNumber,
      activeOk:        ctx.pool.lastState != idleSyncState,

      nHdrStaged:      ctx.headersStagedQueueLen(),
      hdrStagedTop:    ctx.headersStagedQueueTopKey(),
      hdrUnprocTop:    ctx.headersUnprocTotalTop(),
      nHdrUnprocessed: ctx.headersUnprocTotal(),
      nHdrUnprocFragm: ctx.hdr.unprocessed.chunks(),

      nBlkStaged:      ctx.blocksStagedQueueLen(),
      blkStagedBottom: ctx.blocksStagedQueueBottomKey(),
      blkUnprocBottom: ctx.blocksUnprocTotalBottom(),
      nBlkUnprocessed: ctx.blocksUnprocTotal(),
      nBlkUnprocFragm: ctx.blk.unprocessed.chunks(),

      state:           ctx.pool.lastState,
      reorg:           ctx.pool.nReorg,
      nBuddies:        ctx.pool.nBuddies)

  proc tickerLogger(t: TickerRef; ctx: BeaconCtxRef) =
    let
      data = ctx.updater()
      now = Moment.now()

    if now <= t.visited + tickerLogInterval:
      return

    if data != t.lastStats or
      tickerLogSuppressMax < (now - t.visited):
      let
        B = if data.base == data.latest: "L" else: data.base.bnStr
        L = if data.latest == data.coupler: "C" else: data.latest.bnStr
        C = if data.coupler == data.dangling: "D"
            elif data.coupler < high(int64).uint64: data.coupler.bnStr
            else: "n/a"
        D = if data.dangling == data.head: "H" else: data.dangling.bnStr
        H = if data.head == data.target: "T"
            elif data.activeOk: data.head.bnStr
            else: "?" & $data.head
        T = if data.activeOk: data.target.bnStr else: "?" & $data.target

        hS = if data.nHdrStaged == 0: "n/a"
            else: data.hdrStagedTop.bnStr & "[" & $data.nHdrStaged & "]"
        hU = if data.nHdrUnprocFragm == 0 and data.nHdrUnprocessed == 0: "n/a"
            elif data.hdrUnprocTop == 0:
              "(" & data.nHdrUnprocessed.toSI & "," &
                    $data.nHdrUnprocFragm & ")"
            else: data.hdrUnprocTop.bnStr & "(" &
                  data.nHdrUnprocessed.toSI & "," & $data.nHdrUnprocFragm & ")"
        hQ = if hS == "n/a": hU
             elif hU == "n/a": hS
             else: hS & "<-" & hU

        bS = if data.nBlkStaged == 0: "n/a"
            else: data.blkStagedBottom.bnStr & "[" & $data.nBlkStaged & "]"
        bU = if data.nBlkUnprocFragm == 0 and data.nBlkUnprocessed == 0: "n/a"
            elif data.blkUnprocBottom == high(BlockNumber):
              "(" & data.nBlkUnprocessed.toSI & "," &
                    $data.nBlkUnprocFragm & ")"
            else: data.blkUnprocBottom.bnStr & "(" &
                  data.nBlkUnprocessed.toSI & "," & $data.nBlkUnprocFragm & ")"
        bQ = if bS == "n/a": bU
             elif bU == "n/a": bS
             else: bS & "<-" & bU

        st = case data.state
            of idleSyncState: "0"
            of collectingHeaders: "h"
            of cancelHeaders: "x"
            of finishedHeaders: "f"
            of processingBlocks: "b"
            of cancelBlocks: "z"
        rrg = data.reorg
        nP = data.nBuddies

        # With `int64`, there are more than 29*10^10 years range for seconds
        up = (now - t.started).seconds.uint64.toSI
        mem = getTotalMem().uint.toSI

      t.lastStats = data
      t.visited = now

      notice "Sync state", up, nP, st, B, L, C, D, H, T, hQ, bQ, rrg, mem

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

when enableTicker:
  proc updateTicker*(ctx: BeaconCtxRef) =
    if ctx.pool.ticker.isNil:
      ctx.pool.ticker = TickerRef(started: Moment.now())
    ctx.pool.ticker.TickerRef.tickerLogger(ctx)
else:
  template updateTicker*(ctx: BeaconCtxRef) = discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
