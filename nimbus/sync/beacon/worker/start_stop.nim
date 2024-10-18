# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/eth/[common, p2p],
  ../../../core/chain,
  ../../protocol,
  ../worker_desc,
  "."/[blocks_staged, blocks_unproc, db, headers_staged, headers_unproc]

when enableTicker:
  import ./start_stop/ticker

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

when enableTicker:
  proc tickerUpdater(ctx: BeaconCtxRef): TickerStatsUpdater =
    ## Legacy stuff, will be probably be superseded by `metrics`
    return proc: auto =
      TickerStats(
        stored:          ctx.db.getSavedStateBlockNumber(),
        base:            ctx.chain.baseNumber(),
        latest:          ctx.chain.latestNumber(),
        coupler:         ctx.layout.coupler,
        dangling:        ctx.layout.dangling,
        final:           ctx.layout.final,
        head:            ctx.layout.head,
        target:          ctx.target.consHead.number,
        targetOk:        ctx.target.final != 0,

        nHdrStaged:      ctx.headersStagedQueueLen(),
        hdrStagedTop:    ctx.headersStagedTopKey(),
        hdrUnprocTop:    ctx.headersUnprocTop(),
        nHdrUnprocessed: ctx.headersUnprocTotal() + ctx.headersUnprocBorrowed(),
        nHdrUnprocFragm: ctx.headersUnprocChunks(),

        nBlkStaged:      ctx.blocksStagedQueueLen(),
        blkStagedBottom: ctx.blocksStagedBottomKey(),
        blkUnprocTop:    ctx.blk.topRequest,
        nBlkUnprocessed: ctx.blocksUnprocTotal() + ctx.blocksUnprocBorrowed(),
        nBlkUnprocFragm: ctx.blocksUnprocChunks(),

        reorg:           ctx.pool.nReorg,
        nBuddies:        ctx.pool.nBuddies)

proc updateBeaconHeaderCB(ctx: BeaconCtxRef): ReqBeaconSyncTargetCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  return proc(h: Header; f: Hash32) {.gcsafe, raises: [].} =
    # Rpc checks empty header against a zero hash rather than `emptyRoot`
    if not ctx.target.locked:
      if f != zeroHash32 and ctx.target.consHead.number < h.number:
        ctx.target.consHead = h
        ctx.target.final = BlockNumber(0)
        ctx.target.finalHash = f
        ctx.target.changed = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

when enableTicker:
  proc setupTicker*(ctx: BeaconCtxRef) =
    ## Helper for `setup()`: Start ticker
    ctx.pool.ticker = TickerRef.init(ctx.tickerUpdater)

  proc destroyTicker*(ctx: BeaconCtxRef) =
    ## Helper for `release()`
    ctx.pool.ticker.destroy()
    ctx.pool.ticker = TickerRef(nil)

else:
  template setupTicker*(ctx: BeaconCtxRef) = discard
  template destroyTicker*(ctx: BeaconCtxRef) = discard

# ---------

proc setupDatabase*(ctx: BeaconCtxRef) =
  ## Initalise database related stuff

  # Initialise up queues and lists
  ctx.headersStagedInit()
  ctx.blocksStagedInit()
  ctx.headersUnprocInit()
  ctx.blocksUnprocInit()

  # Load initial state from database if there is any
  ctx.dbLoadSyncStateLayout()

  # Set blocks batch import value for block import
  if ctx.pool.nBodiesBatch < nFetchBodiesRequest:
    if ctx.pool.nBodiesBatch == 0:
      ctx.pool.nBodiesBatch = nFetchBodiesBatchDefault
    else:
      ctx.pool.nBodiesBatch = nFetchBodiesRequest

  # Set length of `staged` queue
  if ctx.pool.nBodiesBatch < nFetchBodiesBatchDefault:
    const nBlocks = blocksStagedQueueLenMaxDefault * nFetchBodiesBatchDefault
    ctx.pool.blocksStagedQuLenMax =
      (nBlocks + ctx.pool.nBodiesBatch - 1) div ctx.pool.nBodiesBatch
  else:
    ctx.pool.blocksStagedQuLenMax = blocksStagedQueueLenMaxDefault


proc setupRpcMagic*(ctx: BeaconCtxRef) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  ctx.pool.chain.com.reqBeaconSyncTarget = ctx.updateBeaconHeaderCB

proc destroyRpcMagic*(ctx: BeaconCtxRef) =
  ## Helper for `release()`
  ctx.pool.chain.com.reqBeaconSyncTarget = ReqBeaconSyncTargetCB(nil)

# ---------

proc startBuddy*(buddy: BeaconBuddyRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and peer.state(protocol.eth).initialized:
    ctx.pool.nBuddies.inc # for metrics
    return true

proc stopBuddy*(buddy: BeaconBuddyRef) =
  buddy.ctx.pool.nBuddies.dec # for metrics

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
