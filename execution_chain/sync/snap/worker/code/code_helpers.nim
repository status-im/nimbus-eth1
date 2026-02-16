# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/chronos,
  ../[helpers, worker_desc]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc updateErrorState(buddy: SnapPeerRef) =
  ## Helper/wrapper
  if ((0 < buddy.nErrors.fetch.cde or
       0 < buddy.nErrors.apply.cde) and buddy.ctrl.stopped) or
     nFetchCodesSnapErrThreshold < buddy.nErrors.fetch.cde or
     nProcCodesErrThreshold < buddy.nErrors.apply.cde:

    # Make sure that this peer does not immediately reconnect
    buddy.ctrl.zombie = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func cdeErrors*(buddy: SnapPeerRef): string =
  $buddy.nErrors.fetch.cde & "/" & $buddy.nErrors.apply.cde

proc cdeFetchRegisterError*(
    buddy: SnapPeerRef;
    slowPeer = false;
    forceZombie = false;
      ) =
  buddy.nErrors.fetch.cde.inc
  if nFetchCodesSnapErrThreshold < buddy.nErrors.fetch.cde:
    if not forceZombie and buddy.ctx.nSyncPeers() == 1 and slowPeer:
      # The current peer is the last one and is lablelled `slow`. It would
      # have been zombified if it were not the last one. So it can still
      # keep download going untill the peer pool is replenished with
      # non-`slow` peers.
      buddy.ctx.pool.lastSlowPeer = Opt.some(buddy.peerID)
    else:
      # abandon `slow` peer as it is not the last one in the pool
      buddy.ctrl.zombie = true

proc cdeProcRegisterError*(buddy: SnapPeerRef) =
  buddy.nErrors.apply.cde.inc
  buddy.updateErrorState()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
