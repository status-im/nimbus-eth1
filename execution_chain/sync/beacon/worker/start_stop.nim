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
  pkg/chronicles,
  pkg/eth/common,
  ../../../networking/p2p,
  ../../wire_protocol,
  ../worker_desc,
  ./blocks_staged/staged_queue,
  ./headers_staged/staged_queue,
  ./[blocks_unproc, headers_unproc, update]

type
  SyncStateData = tuple
    start, current, target: BlockNumber

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc querySyncProgress(ctx: BeaconCtxRef): SyncStateData =
  ## Syncer status query function (for call back closure)
  if collectingHeaders <= ctx.pool.lastState:
    return (ctx.chain.baseNumber, ctx.dangling.number, ctx.head.number)
  # (0,0,0)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc setupServices*(ctx: BeaconCtxRef; info: static[string]) =
  ## Helper for `setup()`: Enable external call-back based services

  # Initialise up queues and lists
  ctx.headersStagedQueueInit()
  ctx.blocksStagedQueueInit()
  ctx.headersUnprocInit()
  ctx.blocksUnprocInit()

  # Start in suspended mode
  ctx.hibernate = true

  # Take it easy and assume that queue records contain full block list (which
  # is mostly the case anyway.) So the the staging queue is limited by the
  # number of sub-list records rather than the number of accumulated block
  # objects.
  let hwm = if blocksStagedLwm <= ctx.pool.blkStagedHwm: ctx.pool.blkStagedHwm
            else: blocksStagedHwmDefault
  ctx.pool.blkStagedLenHwm = (hwm + nFetchBodiesBatch - 1) div nFetchBodiesBatch

  # Set blocks batch import queue size
  if ctx.pool.blkStagedHwm != 0:
    debug info & ": import block lists queue", limit=ctx.pool.blkStagedLenHwm
  ctx.pool.blkStagedHwm = hwm

  # Set up header cache descriptor. This will evenually be integrated
  # into `ForkedChainRef` (i.e. `ctx.pool.chain`.)
  ctx.pool.hdrCache = HeaderChainRef.init(ctx.pool.chain)

  # Set up the notifier informing when a new syncer session has started.
  ctx.hdrCache.start proc() =
    # Activates the syncer. Work will be picked up by peers when available.
    ctx.updateFromHibernateSetTarget info

  # Manual first run?
  if 0 < ctx.clReq.consHead.number:
    debug info & ": pre-set target", consHead=ctx.clReq.consHead.bnStr,
      finalHash=ctx.clReq.finalHash.short
    ctx.hdrCache.headTargetUpdate(ctx.clReq.consHead, ctx.clReq.finalHash)

  # Provide progress info call back handler
  ctx.pool.chain.com.beaconSyncerProgress = proc(): SyncStateData =
    ctx.querySyncProgress()


proc destroyServices*(ctx: BeaconCtxRef) =
  ## Helper for `release()`
  ctx.hdrCache.destroy()
  ctx.pool.chain.com.beaconSyncerProgress = BeaconSyncerProgressCB(nil)

# ---------

proc startBuddy*(buddy: BeaconBuddyRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if peer.supports(eth69) and
     peer.state(eth69).initialized:
    ctx.pool.nBuddies.inc
    buddy.initHdrProcErrors()
    return true

  if peer.supports(eth68) and
     peer.state(eth68).initialized:
    ctx.pool.nBuddies.inc
    buddy.initHdrProcErrors()
    return true

proc stopBuddy*(buddy: BeaconBuddyRef) =
  buddy.ctx.pool.nBuddies.dec
  buddy.clearHdrProcErrors()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
