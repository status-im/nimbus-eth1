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
# Public functions
# ------------------------------------------------------------------------------

func bdyErrors*(buddy: BeaconBuddyRef): string =
  $buddy.only.nRespErrors.blk & "/" & $buddy.only.nProcErrors.blk

proc bdyFetchRegisterError*(buddy: BeaconBuddyRef, slowPeer = false) =
  buddy.only.nRespErrors.blk.inc
  if nFetchBodiesErrThreshold < buddy.only.nRespErrors.blk:
    if buddy.ctx.pool.nBuddies == 1 and slowPeer:
      # Remember that the current peer is the last one and is lablelled slow.
      # It would have been zombified if it were not the last one. This can be
      # used in functions -- depending on context -- that will trigger if the
      # if the pool of available sync peers becomes empty.
      buddy.ctx.pool.lastSlowPeer = Opt.some(buddy.peerID)
    else:
      buddy.ctrl.zombie = true # abandon slow peer unless last one

# -------------

func blkSessionStopped*(ctx: BeaconCtxRef): bool =
  ## Helper, checks whether there is a general stop conditions based on
  ## state settings (not on sync peer ctrl as `buddy.ctrl.running`.)
  ctx.poolMode or
  ctx.pool.lastState != SyncState.blocks

func blkThroughput*(buddy: BeaconBuddyRef): string =
  ## Print throuhput sratistics
  buddy.only.thruPutStats.blk.toMeanVar.psStr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
