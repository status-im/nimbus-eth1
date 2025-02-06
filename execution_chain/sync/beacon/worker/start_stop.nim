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

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc queryProgressCB(
    ctx: BeaconCtxRef;
    info: static[string];
      ): BeaconSyncerProgressCB =
  ## Syncer status query function/closure.
  return proc(): tuple[start, current, target: BlockNumber] =
    if not ctx.hibernate():
      return (ctx.layout.coupler,
              max(ctx.layout.coupler,
                  min(ctx.chain.latestNumber(), ctx.layout.head)),
              ctx.layout.head)
    # (0,0,0)

proc updateBeaconHeaderCB(
    ctx: BeaconCtxRef;
    info: static[string];
      ): ReqBeaconSyncerTargetCB =
  ## Update beacon header. This function is intended as a call back function
  ## for the RPC module.
  return proc(h: Header; f: Hash32) {.gcsafe, raises: [].} =

    # Check whether there is an update running (otherwise take next upate)
    if not ctx.target.locked and                 # ignore if currently updating
       ctx.target.final == 0 and                 # ignore if complete already
       f != zeroHash32 and                       # finalised hash is set
       ctx.layout.head < h.number and            # update is advancing
       ctx.target.consHead.number < h.number:    # .. ditto

      ctx.target.consHead = h
      ctx.target.finalHash = f
      ctx.target.changed = true

      # Check whether `FC` knows about the finalised block already.
      #
      # On a full node, all blocks before the current state are stored on the
      # database which is also accessed by `FC`. So one can already decude here
      # whether `FC` id capable of handling that finalised block (the number of
      # must be at least the `base` from `FC`.)
      #
      # Otherwise the block header will need to be fetched from a peer when
      # available and checked there (see `headerStagedUpdateTarget()`.)
      #
      let finHdr = ctx.chain.headerByHash(f).valueOr: return
      ctx.updateFinalBlockHeader(finHdr, f, info)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

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


proc setupServices*(ctx: BeaconCtxRef; info: static[string]) =
  ## Helper for `setup()`: Enable external call-back based services
  # Activate target request. Will be called from RPC handler.
  ctx.pool.chain.com.reqBeaconSyncerTarget = ctx.updateBeaconHeaderCB info
  # Provide progress info
  ctx.pool.chain.com.beaconSyncerProgress = ctx.queryProgressCB info

proc destroyServices*(ctx: BeaconCtxRef) =
  ## Helper for `release()`
  ctx.pool.chain.com.reqBeaconSyncerTarget = ReqBeaconSyncerTargetCB(nil)
  ctx.pool.chain.com.beaconSyncerProgress = BeaconSyncerProgressCB(nil)

# ---------

proc startBuddy*(buddy: BeaconBuddyRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if peer.supports(protocol.eth) and peer.state(protocol.eth).initialized:
    ctx.pool.nBuddies.inc
    return true

proc stopBuddy*(buddy: BeaconBuddyRef) =
  let ctx = buddy.ctx
  ctx.pool.nBuddies.dec

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
