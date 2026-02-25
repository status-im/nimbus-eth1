# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  std/strutils,
  pkg/[chronos, chronicles, metrics, minilru],
  ../../../networking/p2p,
  ../../wire_protocol,
  ./[mpt, state_db, worker_desc]

declareGauge nec_snap_peers, "" &
  "Number of currently active snap instances"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template setLastPeerSeen(ctx: SnapCtxRef) =
  ## Set logger control
  ctx.pool.lastPeerSeen = Moment.now()
  ctx.pool.lastNoPeersLog = ctx.pool.lastPeerSeen

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc setupServices*(ctx: SnapCtxRef; info: static[string]): bool =
  ## Helper for `setup()`: Enable external call-back based services

  # Set up accouning DB
  ctx.pool.stateDB = StateDbRef.init()

  # Set up assembly DB
  ctx.pool.mptAsm = MptAsmRef.init(ctx.pool.baseDir, true, info).valueOr:
    return false

  # Set up ticker, disabled by default
  if ctx.pool.ticker.isNil:
    ctx.pool.ticker = proc(ctx: SnapCtxRef) = discard

  true

proc destroyServices*(ctx: SnapCtxRef) =
  ## Helper for `release()`
  if not ctx.pool.mptAsm.isNil:
    ctx.pool.mptAsm.close()
    ctx.pool.mptAsm = MptAsmRef(nil)

# ---------

proc startSyncPeer*(buddy: SnapPeerRef): bool =
  ## Convenience setting for starting a new worker
  let
    ctx = buddy.ctx
    nSnapPeers = ctx.nSyncPeers() + 1      # current peer is not yet registered

  # Initialise peer data
  buddy.only.peerType = buddy.peer.clientId.split('/',1)[0]
  buddy.only.failedReq = PeerFirstFetchReq(
    stateRoot: StateRootSet.init stateDbCapacity)

  # Reset global register for fall-back peer
  ctx.pool.lastSlowPeer = Opt.none(Hash)

  metrics.set(nec_snap_peers, nSnapPeers)
  true

proc stopSyncPeer*(buddy: SnapPeerRef) =
  let
    ctx = buddy.ctx
    nSnapPeers = ctx.nSyncPeers() - 1      # current peer is still registered

  if nSnapPeers < 1:
    ctx.pool.lastSlowPeer = Opt.none(Hash)
    ctx.setLastPeerSeen()

  metrics.set(nec_snap_peers, nSnapPeers)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
