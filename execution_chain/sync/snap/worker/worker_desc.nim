# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/[eth/common, results],
  ../../../core/chain,
  ../../sync_desc,
  ./worker_const

from ../../beacon
  import BeaconPeerRef, BeaconSyncRef

export
  chain, common, sync_desc, results, worker_const


type
  SnapPeerRef* = SyncPeerRef[SnapCtxData,SnapPeerData]
    ## Extended worker peer descriptor

  SnapCtxRef* = CtxRef[SnapCtxData,SnapPeerData]
    ## Extended global descriptor

  # -------------------

  PeerRanking* = tuple
    assessed: PerfClass
    ranking: int

  # -------------------

  SnapPeerData* = object
    ## Local descriptor data extension

  SnapCtxData* = object
    ## Globally shared data extension
    beaconSync*: BeaconSyncRef       ## Beacon syncer to resume after snap sync

    # Preloading/manual state update
    initBlockHash*: Hash32           ## Optional for setting up root target
    stateUpdateFile*: string         ## Read block hash/number from file

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func chain*(ctx: SnapCtxRef): ForkedChainRef =
  ## Getter
  ctx.pool.beaconSync.ctx.pool.chain

proc getSnapPeer*(buddy: SnapPeerRef; peerID: Hash): SnapPeerRef =
  ## Getter, retrieve syncer peer (aka buddy) by `peerID` argument.
  if buddy.peerID == peerID: buddy else: buddy.ctx.getSyncPeer peerID

proc getEthPeer*(buddy: SnapPeerRef): BeaconPeerRef =
  ## Get the `eth` peer context for the current peer. This context is needed
  ## for running `eth` protocol requests.
  buddy.ctx.pool.beaconSync.ctx.getSyncPeer buddy.peerID

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
