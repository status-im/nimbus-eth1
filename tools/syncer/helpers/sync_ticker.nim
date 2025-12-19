# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronos, chronicles, eth/common, stew/interval_set],
  ../../../execution_chain/sync/beacon/worker/[
    blocks, headers, helpers, worker_desc]

logScope:
  topics = "beacon ticker"

type
  TickerStats = object
    ## Full sync state (see `TickerFullStatsUpdater`)
    base: BlockNumber
    latest: BlockNumber
    coupler: BlockNumber
    dangling: BlockNumber
    top: BlockNumber
    head: BlockNumber
    fin: BlockNumber
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

    state: SyncState
    standByMode: bool
    nSyncPeers: int
    eta: chronos.Duration

  TickerRef = ref object
    ## Ticker descriptor object
    started: Moment
    visited: Moment
    lastStats: TickerStats

# ------------------------------------------------------------------------------
# Private functions: printing ticker messages
# ------------------------------------------------------------------------------

const
  tickerLogInterval = chronos.seconds(2)
  tickerLogSuppressMax = chronos.seconds(100)
  tickerLogStandByMax = chronos.seconds(200)

proc updater(ctx: BeaconCtxRef): TickerStats =
  ## Legacy stuff, will be probably be superseded by `metrics`
  TickerStats(
    base:            ctx.chain.baseNumber,
    latest:          ctx.chain.latestNumber,
    coupler:         ctx.headersUnprocTotalBottom(),
    dangling:        ctx.hdrCache.antecedent.number,
    top:             ctx.subState.topNum,
    head:            ctx.subState.headNum,
    fin:             ctx.chain.resolvedFinNumber,
    target:          ctx.hdrCache.latestConsHeadNumber,
    activeOk:        ctx.pool.syncState != idle,

    nHdrStaged:      ctx.headersStagedQueueLen(),
    hdrStagedTop:    ctx.headersStagedQueueTopKey(),
    hdrUnprocTop:    ctx.headersUnprocTotalTop(),
    nHdrUnprocessed: ctx.headersUnprocTotal(),
    nHdrUnprocFragm: ctx.hdr.unprocessed.chunks,

    nBlkStaged:      ctx.blocksStagedQueueLen(),
    blkStagedBottom: ctx.blocksStagedQueueBottomKey(),
    blkUnprocBottom: ctx.blocksUnprocTotalBottom(),
    nBlkUnprocessed: ctx.blocksUnprocTotal(),
    nBlkUnprocFragm: ctx.blk.unprocessed.chunks,

    state:           ctx.pool.syncState,
    standByMode:     ctx.pool.standByMode,
    nSyncPeers:      ctx.nSyncPeers(),
    eta:             ctx.pool.syncEta.avg)

proc tickerLogger(t: TickerRef; ctx: BeaconCtxRef) =
  let
    data = ctx.updater()
    now = Moment.now()
    elapsed = now - t.visited

  if elapsed <= tickerLogInterval:
    return

  if data.standByMode:
    if elapsed <= tickerLogStandByMax:
      return
  elif data == t.lastStats and
       elapsed <= tickerLogSuppressMax:
    return

  let
    B = if data.base == data.latest: "L" else: $data.base
    L = if data.latest == data.coupler: "C" else: $data.latest
    I = if data.top == 0: "n/a" else : $data.top
    C = if data.coupler == data.dangling: "D"
        elif data.coupler < high(int64).uint64: $data.coupler
        else: "n/a"
    D = if data.dangling == data.head: "H" else: $data.dangling
    H = if data.head == data.target: "T"
        elif data.activeOk: $data.head
        else: "?" & $data.head
    T = if data.activeOk: $data.target else: "?" & $data.target
    F = if data.fin == 0: "n/a"
        elif data.fin == data.target and data.activeOk: "T"
        elif data.fin == data.head: "H"
        elif data.fin == data.dangling: "D"
        elif data.fin == data.latest: "L"
        elif data.fin == data.base: "B"
        else: $data.fin

    hS = if data.nHdrStaged == 0: "n/a"
        else: $data.hdrStagedTop & "[" & $data.nHdrStaged & "]"
    hU = if data.nHdrUnprocFragm == 0 and data.nHdrUnprocessed == 0: "n/a"
        elif data.hdrUnprocTop == 0:
          "(" & data.nHdrUnprocessed.toSI & "," & $data.nHdrUnprocFragm & ")"
        else: $data.hdrUnprocTop & "(" &
              data.nHdrUnprocessed.toSI & "," & $data.nHdrUnprocFragm & ")"
    hQ = if hS == "n/a": hU
         elif hU == "n/a": hS
         else: hS & "<-" & hU

    bS = if data.nBlkStaged == 0: "n/a"
        else: $data.blkStagedBottom & "[" & $data.nBlkStaged & "]"
    bU = if data.nBlkUnprocFragm == 0 and data.nBlkUnprocessed == 0: "n/a"
        elif data.blkUnprocBottom == high(BlockNumber):
          "(" & data.nBlkUnprocessed.toSI & "," & $data.nBlkUnprocFragm & ")"
        else: $data.blkUnprocBottom & "(" &
              data.nBlkUnprocessed.toSI & "," & $data.nBlkUnprocFragm & ")"
    bQ = if bS == "n/a": bU
         elif bU == "n/a": bS
         else: bS & "<-" & bU

    st = case data.state
      of idle: "0"
      of headers: "h"
      of headersCancel: "x"
      of headersFinish: "f"
      of blocks: "b"
      of blocksCancel: "x"
      of blocksFinish: "f"

    nP = data.nSyncPeers

    # With `int64`, there are more than 29*10^10 years range for seconds
    up = (now - t.started).toStr
    eta = data.eta.toStr

  t.lastStats = data
  t.visited = now

  if data.standByMode:
    debug "Sync stand-by mode", up, eta, nP, B, L,
      D, H, T, F
  else:
    case data.state
    of idle:
      debug "Sync state idle", up, eta, nP, B, L,
        D, H, T, F

    of headers, headersCancel, headersFinish:
      debug "Sync state headers", up, eta, nP, st, B, L,
        C, D, H, T, F, hQ

    of blocks, blocksCancel, blocksFinish:
      debug "Sync state blocks", up, eta, nP, st, B, L,
        D, I, H, T, F, bQ

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

proc syncTicker*(): Ticker =
  let desc = TickerRef(started: Moment.now())
  return proc(ctx: BeaconCtxRef) =
    desc.tickerLogger(ctx)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
