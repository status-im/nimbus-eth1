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
  ../worker_desc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc updateErrorState(buddy: BeaconBuddyRef) =
  ## Helper/wrapper
  if ((0 < buddy.only.nRespErrors.hdr or
       0 < buddy.nHdrProcErrors()) and buddy.ctrl.stopped) or
     nFetchHeadersErrThreshold < buddy.only.nRespErrors.hdr or
     nProcHeadersErrThreshold < buddy.nHdrProcErrors():

    # Make sure that this peer does not immediately reconnect
    buddy.ctrl.zombie = true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func hdrErrors*(buddy: BeaconBuddyRef): string =
  $buddy.only.nRespErrors.hdr & "/" & $buddy.nHdrProcErrors()

proc hdrFetchRegisterError*(buddy: BeaconBuddyRef, slowPeer = false) =
  buddy.only.nRespErrors.hdr.inc
  if nFetchHeadersErrThreshold < buddy.only.nRespErrors.hdr:
    if buddy.ctx.pool.nBuddies == 1 and slowPeer:
      # Remember that the current peer is the last one and is lablelled slow.
      # It would have been zombified if it were not the last one. This can be
      # used in functions -- depending on context -- that will trigger if the
      # if the pool of available sync peers becomes empty.
      buddy.ctx.pool.lastSlowPeer = Opt.some(buddy.peerID)
    else:
      buddy.ctrl.zombie = true # abandon slow peer unless last one

proc hdrProcRegisterError*(buddy: BeaconBuddyRef) =
  buddy.incHdrProcErrors()
  buddy.updateErrorState()

# -----------------

func hdrSessionStopped*(ctx: BeaconCtxRef): bool =
  ## Helper, checks whether there is a general stop conditions based on
  ## state settings (not on sync peer ctrl as `buddy.ctrl.running`.)
  ctx.poolMode or
  ctx.pool.lastState != SyncState.headers or
  ctx.hdrCache.state != collecting

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
