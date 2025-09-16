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
  std/[strformat, strutils],
  pkg/[chronos, results, stew/interval_set],
  ../../../../execution_chain/sync/beacon/worker/helpers as worker_helpers,
  ../trace_desc

export
  worker_helpers

# ------------------------------------------------------------------------------
# Public initialisers
# ------------------------------------------------------------------------------

proc init*(tb: var TraceRecBase; ctx: BeaconCtxRef) =
  ## Initialise new trace descriptor. This fuction does nothing if
  ## there is no active trace.
  let trc = ctx.trace
  if not trc.isNil:
    tb.serial =     trc.newSerial
    tb.time =       Moment.now() - trc.started
    tb.syncState =  ctx.pool.lastState
    tb.nPeers =     ctx.pool.nBuddies.uint
    tb.chainMode =  ctx.hdrCache.state
    tb.poolMode =   ctx.poolMode
    tb.baseNum =    ctx.chain.baseNumber
    tb.latestNum =  ctx.chain.latestNumber
    tb.antecedent = ctx.hdrCache.antecedent.number

    let hChunks = ctx.hdr.unprocessed.chunks().uint
    if 0 < hChunks:
      let iv = ctx.hdr.unprocessed.le().expect "valid iv"
      tb.hdrUnpr = Opt.some(TraceHdrUnproc(
        hChunks:  hChunks,
        hLen:     ctx.hdr.unprocessed.total(),
        hLast:    iv.maxPt,
        hLastLen: iv.len))

    let bChunks = ctx.blk.unprocessed.chunks().uint
    if 0 < bChunks:
      let iv = ctx.blk.unprocessed.ge().expect "valid iv"
      tb.blkUnpr = Opt.some(TraceBlkUnproc(
        bChunks:   bChunks,
        bLen:      ctx.blk.unprocessed.total(),
        bLeast:    iv.minPt,
        bLeastLen: iv.len))

    tb.slowPeer = ctx.pool.lastSlowPeer


proc init*(tb: var TraceRecBase; buddy: BeaconBuddyRef) =
  ## Variant of `init()` for `buddy` rather than `ctx`
  let
    ctx = buddy.ctx
    trc = ctx.trace
  if not trc.isNil:
    tb.init ctx
    tb.peerCtx = Opt.some(TracePeerCtx(
      peerCtrl:   buddy.ctrl.state,
      peerID:     buddy.peerID,
      nHdrErrors: buddy.only.nRespErrors.hdr,
      nBlkErrors: buddy.only.nRespErrors.blk))

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func short*(w: Hash): string =
  w.toHex(8).toLowerAscii # strips leading 8 bytes

func idStr*(w: uint64): string =
  &"{w:x}"

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
