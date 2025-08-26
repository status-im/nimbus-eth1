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
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/interval_set,
  ../../../../networking/p2p,
  ../../worker_desc,
  ./[headers_fetch, headers_helpers]

logScope:
  topics = "beacon sync"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headersTargetRequest*(
    ctx: BeaconCtxRef;
    h: Hash32;
    isFinal: bool;
    info: static[string];
      ) =
  ## Request *manual* syncer target. It has to be activated by the
  ## `headersTargetActivate()` function below.
  ctx.pool.initTarget = Opt.some((h,isFinal))
  trace info & ": request syncer target", targetHash=h.short, isFinal

proc headersTargetReset*(ctx: BeaconCtxRef) =
  ## Reset *manual* syncer target.
  ctx.pool.initTarget = Opt.none(InitTarget)


template headersTargetActivate*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) =
  ## Async/template
  ##
  ## Load target header and trigger syncer activation if there is a request
  ## for doing so (i.e. the `initTarget` variable is set.)
  ##
  block body:
    # Check whether a target is available at all.
    let ctx = buddy.ctx
    if ctx.pool.initTarget.isNone():
      break body                                           # return

    let
      peer {.inject.} = buddy.peer
      trg = ctx.pool.initTarget.unsafeGet

    # Require minimum of sync peers
    if ctx.pool.nBuddies < ctx.pool.minInitBuddies:
      trace info & ": not enough buddies required to start sync", peer,
        targetHash=trg.hash.short, isFinal=trg.isFinal,
        syncState=($buddy.syncState), nSyncPeers=ctx.pool.nBuddies
      break body                                           # return

    # Can be used only before first activation
    if ctx.pool.lastState != SyncState.idle:
      debug info & ": cannot setup target while syncer is activated", peer,
        targetHash=trg.hash.short, isFinal=trg.isFinal,
        syncState=($buddy.syncState), nSyncPeers=ctx.pool.nBuddies
      ctx.pool.initTarget = Opt.none(InitTarget)
      break body                                           # return

    # Ignore failed peers
    if buddy.peerID in ctx.pool.failedPeers:
      break body                                           # return

    # Grab header, so no other peer will interfere
    ctx.pool.initTarget = Opt.none(InitTarget)

    # Fetch header or return
    const iv = BnRange.new(0u,0u) # dummy interval
    let hdrs = buddy.fetchHeadersReversed(iv, trg.hash, info).valueOr:
      if buddy.ctrl.running:
        trace info & ": peer failed on syncer target", peer,
          targetHash=trg.hash.short, isFinal=trg.isFinal,
          failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.pool.nBuddies,
          hdrErrors=buddy.hdrErrors, syncState=($buddy.syncState)
        ctx.pool.initTarget = Opt.some(trg)                # restore target

      else:
        # Collect problematic peers for detecting cul-de-sac syncing
        ctx.pool.failedPeers.incl buddy.peerID

        # Abandon *manual* syncer target if there are too many errors
        if nFetchTargetFailedPeersThreshold < ctx.pool.failedPeers.len:
          warn "No such syncer target, abandoning it", peer,
            targetHash=trg.hash.short, isFinal=trg.isFinal,
            failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.pool.nBuddies,
            hdrErrors=buddy.hdrErrors
          ctx.pool.failedPeers.clear()
          # not restoring target

        else:
          trace info & ": peer repeatedly failed", peer,
            targetHash=trg.hash.short, isFinal=trg.isFinal,
            failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.pool.nBuddies,
            hdrErrors=buddy.hdrErrors, syncState=($buddy.syncState)
          ctx.pool.initTarget = Opt.some(trg)              # restore target

      break body                                           # return
      # End `fetchHeadersReversed(..).valueOr`

    # Got header so the cul-de-sac protection can be cleared
    ctx.pool.failedPeers.clear()

    # Verify that the target header is usable
    let hdr = hdrs[0]
    if hdr.number <= ctx.chain.baseNumber:
      warn "Unusable syncer target, abandoning it", peer, target=hdr.bnStr,
        targetHash=trg.hash.short, isFinal=trg.isFinal,
        base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
        nSyncPeers=ctx.pool.nBuddies
      break body                                           # return
    
    # Start syncer
    debug info & ": activating manually", peer, target=hdr.bnStr,
      targetHash=trg.hash.short, isFinal=trg.isFinal,
      nSyncPeers=ctx.pool.nBuddies

    let finalised = if trg.isFinal: trg.hash else: ctx.chain.baseHash
    ctx.hdrCache.headTargetUpdate(hdr, finalised)
    # End block: `body`

  discard                                                  # visual alignment

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
