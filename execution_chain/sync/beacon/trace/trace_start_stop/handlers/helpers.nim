# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
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
  pkg/[chronos, stew/interval_set],
  ../../../worker/helpers as worker_helpers,
  ../../trace_desc

export
  worker_helpers

# ------------------------------------------------------------------------------
# Public context capture initialisation
# ------------------------------------------------------------------------------

proc init*(tb: var TraceRecBase; ctx: BeaconCtxRef) =
  ## Initialise new trace descriptor. This fuction does nothing if
  ## there is no active trace.
  let trc = ctx.trace
  if not trc.isNil:
    tb.serial =    trc.newSerial
    tb.time =      Moment.now() - trc.started
    tb.syncState = ctx.pool.lastState
    tb.nPeers =    ctx.pool.nBuddies
    tb.chainMode = ctx.hdrCache.state
    tb.poolMode =  ctx.poolMode
    tb.baseNum =   ctx.chain.baseNumber
    tb.latestNum = ctx.chain.latestNumber

    tb.hdrUnprChunks = ctx.hdr.unprocessed.chunks().uint
    if 0 < tb.hdrUnprChunks:
      tb.hdrUnprLen = ctx.hdr.unprocessed.total()
      let iv = ctx.hdr.unprocessed.le().expect "valid iv"
      tb.hdrUnprLast = iv.maxPt
      tb.hdrUnprLastLen = iv.len

    tb.blkUnprChunks = ctx.blk.unprocessed.chunks().uint
    if 0 < tb.blkUnprChunks:
      tb.blkUnprLen = ctx.blk.unprocessed.total()
      let iv = ctx.blk.unprocessed.ge().expect "valid iv"
      tb.blkUnprLeast = iv.minPt
      tb.blkUnprLeastLen = iv.len

    if ctx.pool.lastSlowPeer.isOk():
      tb.stateAvail = 16
      tb.slowPeer = ctx.pool.lastSlowPeer.value
    else:
      tb.stateAvail = 0

proc init*(tb: var TraceRecBase; buddy: BeaconBuddyRef) =
  ## Variant of `init()` for `buddy` rather than `ctx`
  let
    ctx = buddy.ctx
    trc = ctx.trace
  if not trc.isNil:
    tb.init ctx
    tb.stateAvail += 15
    tb.peerCtrl = buddy.ctrl.state
    tb.peerID = buddy.peerID
    tb.nHdrErrors = buddy.only.nRespErrors.hdr
    tb.nBlkErrors = buddy.only.nRespErrors.blk

proc init*(
    tb: var TraceRecBase;
    ctx: BeaconCtxRef;
    maybePeer: Opt[BeaconBuddyRef];
      ) =
  ## Variant of `init()`
  let trc = ctx.trace
  if not trc.isNil:
    if maybePeer.isSome:
      tb.init maybePeer.value
    else:
      tb.init ctx

# --------------

func short*(w: Hash): string =
  w.toHex(8).toLowerAscii # strips leading 8 bytes

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
