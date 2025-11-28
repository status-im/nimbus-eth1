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
  ../worker_desc,
  ./headers_fetch

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
    buddy: BeaconPeerRef;
    info: static[string];
      ): bool =
  ## Async/template
  ##
  ## Load target header and trigger syncer activation if there is a request
  ## for doing so (i.e. the `initTarget` variable is set.) Returns `true`
  ## if there ws something activated.
  ##
  var bodyRc = false
  block body:
    # Check whether a target is available at all.
    let ctx = buddy.ctx

    # Must be called before first syncer activation
    doAssert ctx.pool.syncState == SyncState.idle

    if ctx.pool.initTarget.isNone():
      break body                                           # return

    let
      peer {.inject.} = buddy.peer
      trg = ctx.pool.initTarget.unsafeGet

    # Require minimum of sync peers
    if ctx.nSyncPeers() < ctx.pool.minInitBuddies:
      trace info & ": not enough peers to start manual sync", peer,
        targetHash=trg.hash.short, isFinal=trg.isFinal,
        state=($buddy.syncState),
        nSyncPeersMin=ctx.pool.minInitBuddies, nSyncPeers=ctx.nSyncPeers()
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
          failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.nSyncPeers(),
          nErrors=buddy.nErrors.fetch.hdr, state=($buddy.syncState)
        ctx.pool.initTarget = Opt.some(trg)                # restore target

      else:
        # Collect problematic peers for detecting cul-de-sac syncing
        ctx.pool.failedPeers.incl buddy.peerID

        # Abandon *manual* syncer target if there are too many errors
        if nFetchTargetFailedPeersThreshold < ctx.pool.failedPeers.len:
          warn "No such syncer target, abandoning it", peer,
            targetHash=trg.hash.short, isFinal=trg.isFinal,
            failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.nSyncPeers(),
            nErrors=buddy.nErrors.fetch.hdr
          ctx.pool.failedPeers.clear()
          # not restoring target

        else:
          trace info & ": peer repeatedly failed", peer,
            targetHash=trg.hash.short, isFinal=trg.isFinal,
            failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.nSyncPeers(),
            nErrors=buddy.nErrors.fetch.hdr, state=($buddy.syncState)
          ctx.pool.initTarget = Opt.some(trg)              # restore target

      break body                                           # return
      # End `fetchHeadersReversed(..).valueOr`

    # Got header so the cul-de-sac protection can be cleared
    ctx.pool.failedPeers.clear()

    # Verify that the target header is usable
    let hdr = hdrs[0]
    if hdr.number <= ctx.chain.baseNumber:
      warn "Unusable syncer target, abandoning it", peer, target=hdr.number,
        targetHash=trg.hash.short, isFinal=trg.isFinal,
        base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
        nSyncPeers=ctx.nSyncPeers()
      break body                                           # return
    
    # Start syncer
    debug info & ": activating manually", peer, target=hdr.number,
      targetHash=trg.hash.short, isFinal=trg.isFinal,
      nSyncPeers=ctx.nSyncPeers()

    let finalised = if trg.isFinal: trg.hash else: ctx.chain.baseHash
    ctx.hdrCache.headTargetUpdate(hdr, finalised)

    bodyRc = true
    # End block: `body`

  bodyRc                                                   # return code

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
