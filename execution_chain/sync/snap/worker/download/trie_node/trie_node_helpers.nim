# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises:[].}

import
  pkg/chronos,
  ../../[helpers, worker_desc]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc updateErrorState(buddy: SnapPeerRef) =
  ## Helper/wrapper
  if ((0 < buddy.nErrors.fetch.tri or
       0 < buddy.nErrors.apply.tri) and buddy.ctrl.stopped) or
     nFetchTrieNodeSnapErrThreshold < buddy.nErrors.fetch.tri or
     nProcTrieNodeErrThreshold < buddy.nErrors.apply.tri:

    # Make sure that this peer does not immediately reconnect
    buddy.ctrl.zombie = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func triErrors*(buddy: SnapPeerRef): string =
  $buddy.nErrors.fetch.tri & "/" & $buddy.nErrors.apply.tri

proc triFetchRegisterError*(
    buddy: SnapPeerRef;
    slowPeer = false;
    forceZombie = false;
      ) =
  buddy.nErrors.fetch.tri.inc
  if nFetchTrieNodeSnapErrThreshold < buddy.nErrors.fetch.tri:
    if not forceZombie and buddy.ctx.nSyncPeers() == 1 and slowPeer:
      # The current peer is the last one and is lablelled `slow`. It would
      # have been zombified if it were not the last one. So it can still
      # keep download going untill the peer pool is replenished with
      # non-`slow` peers.
      buddy.ctx.pool.lastSlowPeer = Opt.some(buddy.peerID)
    else:
      # abandon `slow` peer as it is not the last one in the pool
      buddy.ctrl.zombie = true

proc triProcRegisterError*(buddy: SnapPeerRef) =
  buddy.nErrors.apply.tri.inc
  buddy.updateErrorState()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
