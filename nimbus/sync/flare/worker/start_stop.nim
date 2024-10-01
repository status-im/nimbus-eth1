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
  proc tickerUpdater(ctx: FlareCtxRef): TickerFlareStatsUpdater =
    ## Legacy stuff, will be probably be superseded by `metrics`
    result = proc: auto =
      TickerFlareStats(
        stateTop:        ctx.dbStateBlockNumber(),
        base:            ctx.layout.base,
        least:           ctx.layout.least,
        final:           ctx.layout.final,
        beacon:          ctx.lhc.beacon.header.number,

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

        reorg:           ctx.pool.nReorg)

proc updateBeaconHeaderCB(ctx: FlareCtxRef): SyncFinalisedBlockHashCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  return proc(h: Hash32) {.gcsafe, raises: [].} =
    # Rpc checks empty header against a zero hash rather than `emptyRoot`
    if ctx.lhc.beacon.finalised == zeroHash32:
      ctx.lhc.beacon.finalised = h

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

when enableTicker:
  proc setupTicker*(ctx: FlareCtxRef) =
    ## Helper for `setup()`: Start ticker
    ctx.pool.ticker = TickerRef.init(ctx.tickerUpdater)

  proc destroyTicker*(ctx: FlareCtxRef) =
    ## Helper for `release()`
    ctx.pool.ticker.destroy()
    ctx.pool.ticker = TickerRef(nil)

else:
  template setupTicker*(ctx: FlareCtxRef) = discard
  template destroyTicker*(ctx: FlareCtxRef) = discard

# ---------

proc setupDatabase*(ctx: FlareCtxRef) =
  ## Initalise database related stuff

  # Initialise up queues and lists
  ctx.headersStagedInit()
  ctx.blocksStagedInit()
  ctx.headersUnprocInit()
  ctx.blocksUnprocInit()

  # Load initial state from database if there is any
  ctx.dbLoadLinkedHChainsLayout()

  # Set blocks batch import value for `persistBlocks()`
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


proc setupRpcMagic*(ctx: FlareCtxRef) =
  ## Helper for `setup()`: Enable external pivot update via RPC
  ctx.pool.chain.com.syncFinalisedBlockHash = ctx.updateBeaconHeaderCB

proc destroyRpcMagic*(ctx: FlareCtxRef) =
  ## Helper for `release()`
  ctx.pool.chain.com.syncFinalisedBlockHash = SyncFinalisedBlockHashCB(nil)

# ---------

proc startBuddy*(buddy: FlareBuddyRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and peer.state(protocol.eth).initialized:
    ctx.pool.nBuddies.inc # for metrics
    when enableTicker:
      ctx.pool.ticker.startBuddy()
    return true

proc stopBuddy*(buddy: FlareBuddyRef) =
  buddy.ctx.pool.nBuddies.dec # for metrics
  when enableTicker:
    buddy.ctx.pool.ticker.stopBuddy()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
