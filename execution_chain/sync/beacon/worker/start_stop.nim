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
  pkg/[chronicles, eth/common, results],
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
  if blocks <= ctx.pool.lastState:
    return (ctx.hdrCache.antecedent.number, ctx.subState.top, ctx.subState.head)

  if headers <= ctx.pool.lastState:
    let b = ctx.chain.baseNumber
    return (b, b, ctx.subState.head)

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

  # Set up header cache descriptor
  ctx.pool.hdrCache = HeaderChainRef.init(ctx.chain)

  # Set up the notifier informing when a new syncer session has started.
  ctx.hdrCache.start proc() =
    # Activates the syncer. Work will be picked up by peers when available.
    ctx.updateFromHibernateSetTarget info

  # Manual first run?
  if 0 < ctx.pool.clReq.consHead.number:
    debug info & ": pre-set target", consHead=ctx.pool.clReq.consHead.bnStr,
      finalHash=ctx.pool.clReq.finalHash.short
    ctx.hdrCache.headTargetUpdate(
      ctx.pool.clReq.consHead, ctx.pool.clReq.finalHash)

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

  template acceptProto(PROTO: type): bool =
    peer.supports(PROTO) and
    peer.state(PROTO).initialized

  if acceptProto(eth69) or
     acceptProto(eth68):
    ctx.pool.nBuddies.inc
    ctx.pool.blkLastSlowPeer = Opt.none(Hash)
    buddy.initHdrProcErrors()
    return true


proc stopBuddy*(buddy: BeaconBuddyRef) =
  buddy.ctx.pool.nBuddies.dec
  buddy.clearHdrProcErrors()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
