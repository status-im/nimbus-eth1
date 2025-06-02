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
  pkg/[chronicles, chronos, eth/common, metrics],
  ../../../networking/p2p,
  ../../wire_protocol,
  ./[blocks, headers, worker_desc]

type
  SyncStateData = tuple
    start, current, target: BlockNumber

declareGauge nec_sync_peers, "" &
  "Number of currently active worker instances"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc querySyncProgress(ctx: BeaconCtxRef): SyncStateData =
  ## Syncer status query function (for call back closure)
  if SyncState.blocks <= ctx.pool.syncState:
    return (ctx.hdrCache.antecedent.number,
            ctx.subState.topNum, ctx.subState.headNum)

  if SyncState.headers <= ctx.pool.syncState:
    let b = ctx.chain.baseNumber
    return (b, b, ctx.subState.headNum)

  # (0,0,0)

template setLastPeerSeen(ctx: BeaconCtxRef) =
  ## Set logger control
  ctx.pool.lastPeerSeen = Moment.now()
  ctx.pool.lastNoPeersLog = ctx.pool.lastPeerSeen

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
  ctx.updateEtaInit()
  ctx.setLastPeerSeen()

  # Start in suspended mode
  ctx.hibernate = true

  # Set up header cache descriptor
  ctx.pool.hdrCache = HeaderChainRef.init(ctx.chain)

  # Set up the notifier informing when a new syncer session has started.
  ctx.hdrCache.start proc() =
    # This directive captures `ctx` for calling the activation handler.
    ctx.handler.activate(ctx)

  # Provide progress info call back handler
  ctx.pool.chain.com.beaconSyncerProgress = proc(): SyncStateData =
    ctx.querySyncProgress()

  # Set up ticker, disabled by default
  if ctx.pool.ticker.isNil:
    ctx.pool.ticker = proc(ctx: BeaconCtxRef) = discard


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
    nSyncPeers = ctx.nSyncPeers() + 1      # current peer is not yet registered

  template acceptProto(PROTO: type): bool =
    peer.supports(PROTO) and
    peer.state(PROTO).initialized

  if acceptProto(eth69) or
     acceptProto(eth68):
    metrics.set(nec_sync_peers, nSyncPeers)
    ctx.pool.lastSlowPeer = Opt.none(Hash)
    return true


proc stopBuddy*(buddy: BeaconBuddyRef) =
  let
    ctx = buddy.ctx
    nSyncPeers = ctx.nSyncPeers() - 1      # current peer is still registered

  if nSyncPeers < 1:
    ctx.pool.lastSlowPeer = Opt.none(Hash)
    ctx.setLastPeerSeen()

  metrics.set(nec_sync_peers, nSyncPeers)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
