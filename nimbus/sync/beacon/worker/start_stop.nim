# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  ./blocks_staged/staged_queue,
  ./headers_staged/staged_queue,
  "."/[blocks_unproc, db, headers_unproc, update]

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
        base:            ctx.chain.baseNumber(),
        latest:          ctx.chain.latestNumber(),
        coupler:         ctx.layout.coupler,
        dangling:        ctx.layout.dangling,
        head:            ctx.layout.head,
        headOk:          ctx.layout.lastState != idleSyncState,
        target:          ctx.target.consHead.number,
        targetOk:        ctx.target.changed,

        nHdrStaged:      ctx.headersStagedQueueLen(),
        hdrStagedTop:    ctx.headersStagedQueueTopKey(),
        hdrUnprocTop:    ctx.headersUnprocTop(),
        nHdrUnprocessed: ctx.headersUnprocTotal() + ctx.headersUnprocBorrowed(),
        nHdrUnprocFragm: ctx.headersUnprocChunks(),

        nBlkStaged:      ctx.blocksStagedQueueLen(),
        blkStagedBottom: ctx.blocksStagedQueueBottomKey(),
        blkUnprocBottom: ctx.blocksUnprocBottom(),
        nBlkUnprocessed: ctx.blocksUnprocTotal() + ctx.blocksUnprocBorrowed(),
        nBlkUnprocFragm: ctx.blocksUnprocChunks(),

        reorg:           ctx.pool.nReorg,
        nBuddies:        ctx.pool.nBuddies)


proc updateBeaconHeaderCB(
    ctx: BeaconCtxRef;
    info: static[string];
      ): ReqBeaconSyncTargetCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  return proc(h: Header) {.gcsafe, raises: [].} =
    if ctx.chain.baseNumber() < h.number and     # sanity check
       ctx.layout.head < h.number and            # update is advancing
       ctx.target.consHead.number < h.number:    # .. ditto
      ctx.target.consHead = h
      ctx.target.changed = true                  # enable this dataset
      ctx.updateFromHibernating info             # wake up if sleeping

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

proc setupDatabase*(ctx: BeaconCtxRef; info: static[string]) =
  ## Initalise database related stuff

  # Initialise up queues and lists
  ctx.headersStagedQueueInit()
  ctx.blocksStagedQueueInit()
  ctx.headersUnprocInit()
  ctx.blocksUnprocInit()

  # Load initial state from database if there is any. If the loader returns
  # `true`, then the syncer will resume from previous sync in which case the
  # system becomes fully active. Otherwise there is some polling only waiting
  # for a new target so there is reduced service (aka `hibernate`.).
  ctx.hibernate = not ctx.dbLoadSyncStateLayout info

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


proc setupRpcMagic*(ctx: BeaconCtxRef; info: static[string]) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  ctx.pool.chain.com.reqBeaconSyncTarget = ctx.updateBeaconHeaderCB info

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
