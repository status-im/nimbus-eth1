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
  pkg/chronos,
  ../update/update_eta,
  ../worker_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc updateErrorState(buddy: BeaconBuddyRef) =
  ## Helper/wrapper
  if ((0 < buddy.nErrors.fetch.hdr or
       0 < buddy.nErrors.apply.hdr) and buddy.ctrl.stopped) or
     nFetchHeadersErrThreshold < buddy.nErrors.fetch.hdr or
     nProcHeadersErrThreshold < buddy.nErrors.apply.hdr:

    # Make sure that this peer does not immediately reconnect
    buddy.ctrl.zombie = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func hdrErrors*(buddy: BeaconBuddyRef): string =
  $buddy.nErrors.fetch.hdr & "/" & $buddy.nErrors.apply.hdr

proc hdrFetchRegisterError*(buddy: BeaconBuddyRef;
     slowPeer = false;
     forceZombie = false;
       ) =
  buddy.nErrors.fetch.hdr.inc
  if nFetchHeadersErrThreshold < buddy.nErrors.fetch.hdr:
    if not forceZombie and buddy.ctx.nSyncPeers() == 1 and slowPeer:
      # The current peer is the last one and is lablelled `slow`. It would
      # have been zombified if it were not the last one. So it can still
      # keep download going untill the peer pool is replenished with
      # non-`slow` peers.
      buddy.ctx.pool.lastSlowPeer = Opt.some(buddy.peerID)
    else:
      # abandon `slow` peer as it is not the last one in the pool
      buddy.ctrl.zombie = true

proc hdrProcRegisterError*(buddy: BeaconBuddyRef) =
  buddy.nErrors.apply.hdr.inc
  buddy.updateErrorState()

# -----------------

func hdrSessionStopped*(ctx: BeaconCtxRef): bool =
  ## Helper, checks whether there is a general stop conditions based on
  ## state settings (not on sync peer ctrl as `buddy.ctrl.running`.)
  ctx.poolMode or
  ctx.pool.syncState != SyncState.headers or
  ctx.hdrCache.state != collecting

func hdrThroughput*(buddy: BeaconBuddyRef): string =
  ## Print throuhput sratistics
  buddy.only.thPutStats.hdr.toMeanVar.toStr

# -------------

proc hdrNoSampleSize*(
    buddy: BeaconBuddyRef;
    elapsed: chronos.Duration;
      ) =
  discard buddy.only.thPutStats.hdr.bpsSample(elapsed, 0)

proc hdrSampleSize*(
    buddy: BeaconBuddyRef;
    elapsed: chronos.Duration;
    size: int;
      ): uint =
  result = buddy.only.thPutStats.hdr.bpsSample(elapsed, size)
  buddy.ctx.updateEtaHeaders()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
