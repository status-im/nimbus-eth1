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
  std/sets,
  pkg/[chronicles, chronos],
  pkg/eth/common,
  pkg/stew/[interval_set, sorted_set],
  ./headers/[headers_headers, headers_helpers, headers_queue, headers_unproc],
  ./worker_desc

export
  headers_queue, headers_unproc

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc bnStrIfAvail(bn: BlockNumber; ctx: BeaconCtxRef): string =
   if ctx.hdrSessionStopped(): "n/a" else: bn.bnStr

proc nUnprocStr(ctx: BeaconCtxRef): string =
  if ctx.hdrSessionStopped() or ctx.headersUnprocTotalBottom() == 0: "n/a"
  else: $(ctx.hdrCache.antecedent.number.uint64 - ctx.headersUnprocTotalBottom)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func headersCollectOk*(buddy: BeaconBuddyRef): bool =
  ## Helper for `worker.nim`, etc.
  if buddy.ctrl.running:
    let ctx = buddy.ctx
    if 0 < ctx.headersUnprocAvail() and
       not ctx.hdrSessionStopped():
      return true
  false


template headersCollect*(buddy: BeaconBuddyRef; info: static[string]) =
  ## Async/template
  ##
  ## Collect headers and either stash them on the header chain cache directly,
  ## or stage then on the header queue to get them serialised, later. The
  ## header queue serialisation is needed in case of several peers fetching
  ## and processing headers concurrently.
  ##
  block body:
    let
      ctx = buddy.ctx
      peer {.inject,used.} = buddy.peer

    if ctx.headersUnprocIsEmpty() or
       ctx.hdrCache.state != collecting:
      break body                                     # no action, return

    var
      stashedOK = false                              # imported some blocks
      nStashed {.inject.} = 0u64                     # statistics, to be updated
      nQueued {.inject.} = 0                         # ditto

    block fetchHeadersBody:
      #
      # Start deterministically. Explicitely fetch/append by parent hash.
      #
      # Exactly one peer can fetch deterministically (i.e. hash based) and
      # store headers directly on the header chain cache. All other peers fetch
      # opportunistcally (i.e. block number based) and queue the headers for
      # later serialisation.
      while true:
        let top = ctx.headersUnprocAvailTop() + 1
        #
        # A deterministic fetch can directly append to the lower end `dangling`
        # of header chain cache. So this criteria is unique at a given time
        # and when an interval is taken out of the `unproc` pool:
        # ::
        #    ------------------|               unproc pool
        #              |-------|               block interval to fetch next
        #                       |----------    already stored headers on cache
        #                      top
        #                    dangling
        #
        # After claiming the block interval that will be processed next for the
        # deterministic fetch, the situation for the new `top` would look like
        # ::
        #    ---------|                        unproc pool
        #              |-------|               block interval to fetch next
        #                       |----------    already stored headers on cache
        #             top     dangling
        #
        # so any other peer arriving here will see a gap between `top` and
        # `dangling` which will lead this peer to fetch opportunistcally.
        #
        let dangling = ctx.hdrCache.antecedent.number
        if top < dangling:
          break # continue with opportunistic fetching & stashing

        # Throw away overlap (should not happen anyway)
        if dangling < top:
          discard ctx.headersUnprocFetch(top - dangling).expect("iv")

        let
          # Get parent hash from the most senior stored header
          parent = ctx.hdrCache.antecedent.parentHash

          # Fetch some headers
          rev = buddy.headersFetch(parent, nFetchHeadersRequest, info).valueOr:
            trace info & ": fetch to disk error ***", peer
            break fetchHeadersBody                   # error => exit block

        ctx.pool.seenData = true                     # header data exist

        # Store it on the header chain cache
        let nHdrs = buddy.headersStashOnDisk(rev, buddy.peerID, info).valueOr:
          break fetchHeadersBody                     # error => exit block

        if nHdrs == 0:
          break fetchHeadersBody                     # nothing achieved

        nStashed += nHdrs                            # statistics

        # Sync status logging
        if 0 < nStashed:
          stashedOK = true
          if ctx.pool.lastSyncUpdLog + syncUpdateLogWaitInterval < Moment.now():
            chronicles.info "Headers stashed", nStashed,
              nUnpoc=ctx.nUnprocStr(),
              nStagedQ=ctx.hdr.staged.len,
              eta=ctx.pool.syncEta.avg.toStr,
              base=ctx.chain.baseNumber.bnStr,
              head=ctx.chain.latestNumber.bnStr,
              target=ctx.hdrCache.head.bnStr,
              thPut=buddy.hdrThroughput,
              nSyncPeers=ctx.nSyncPeers()
            ctx.pool.lastSyncUpdLog = Moment.now()
            nStashed = 0

        if buddy.ctrl.stopped:                       # peer was cancelled
          break fetchHeadersBody                     # done, exit this block

        # End while: `collectAndStashOnDiskCache()`

      # Continue opportunistically fetching by block number rather than hash.
      # The fetched headers need to be staged and checked/serialised later.
      if ctx.hdr.staged.len+ctx.hdr.reserveStaged < headersStagedQueueLengthMax:

        # Fetch headers
        ctx.hdr.reserveStaged.inc                    # Book a slot on `staged`
        let rc = buddy.headersFetch(EMPTY_ROOT_HASH, nFetchHeadersRequest, info)
        ctx.hdr.reserveStaged.dec                    # Free that slot again

        if rc.isErr:
          break fetchHeadersBody                     # done, exit this block

        let
          # Insert headers list on the `staged` queue
          key = rc.value[0].number
          qItem = ctx.headersStagedQueueInsert(key).valueOr:
            raiseAssert info & ": duplicate key on staged queue" &
              " iv=" & (rc.value[^1].number,key).bnStr
        qItem.data.revHdrs = rc.value
        qItem.data.peerID = buddy.peerID
        nQueued = rc.value.len                       # statistics
        # End if

      # End block: `fetchHeadersBody`

    if stashedOK:
      # Sync status logging.
      if 0 < nStashed:
        # Note that `nStashed` might have been reset above.
        chronicles.info "Headers stashed", nStashed,
          nUnpoc=ctx.nUnprocStr(),
          nStagedQ=ctx.hdr.staged.len,
          eta=ctx.pool.syncEta.avg.toStr,
          base=ctx.chain.baseNumber.bnStr,
          head=ctx.chain.latestNumber.bnStr,
          target=ctx.hdrCache.head.bnStr,
          thPut=buddy.hdrThroughput,
          nSyncPeers=ctx.nSyncPeers()
        ctx.pool.lastSyncUpdLog = Moment.now()

    elif nQueued == 0 and
         not ctx.pool.seenData and
         buddy.peerID notin ctx.pool.failedPeers and
         buddy.ctrl.stopped:
      # Collect peers for detecting cul-de-sac syncing (i.e. non-existing
      # block chain or similar.)
      ctx.pool.failedPeers.incl buddy.peerID

      debug info & ": no headers yet (failed peer)", peer,
        failedPeers=ctx.pool.failedPeers.len, nSyncPeers=ctx.nSyncPeers(),
        state=($buddy.syncState), nErrors=buddy.hdrErrors()
      break body

    # This message might run in addition to the `chronicles.info` part
    trace info & ": queued/staged or DB/stored headers", peer,
      unprocAvailTop=ctx.headersUnprocAvailTop.bnStrIfAvail(ctx),
      nQueued, nStashed, nStagedQ=ctx.hdr.staged.len,
      nSyncPeers=ctx.nSyncPeers()
    # End block: `body`

  discard

# --------------

proc headersUnstageOk*(buddy: BeaconBuddyRef): bool =
  ## Check whether import processing is possible
  ##
  let ctx = buddy.ctx
  not ctx.poolMode and
  0 < ctx.hdr.staged.len

proc headersUnstage*(buddy: BeaconBuddyRef; info: static[string]): bool =
  ## Store headers from the `staged` queue onto the header chain cache.
  ##
  ## The function returns `false` if the caller should make sure to allow
  ## to switch to another sync peer for deterministically filling the gap
  ## between the top of the queue and the `dangling` block number.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if ctx.hdr.staged.len == 0:
    return false                                             # switch peer

  var
    nStashed = 0u64                                          # statistics
    nUnstaged = 0                                            # ditto
    switchPeer = false                                       # for return code

  while ctx.hdrCache.state == collecting:

    # Fetch list with largest block numbers
    let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
      break                                                  # all done

    let
      minNum = qItem.data.revHdrs[^1].number
      maxNum = qItem.data.revHdrs[0].number
      dangling = ctx.hdrCache.antecedent.number
    if maxNum + 1 < dangling:
      let unprocTop = ctx.headersUnprocTotalTop()
      trace info & ": gap, serialisation postponed", peer,
        qItem=qItem.data.revHdrs.bnStr, unprocTop=unprocTop.bnStr,
        D=dangling.bnStr, nStashed, nStagedQ=ctx.hdr.staged.len,
        nSyncPeers=ctx.nSyncPeers()
      switchPeer = true # there is a gap -- come back later
      # Impossible situation => deadlock
      doAssert dangling <= unprocTop + 1
      break

    # Remove from queue
    ctx.headersStagedQueueDelete(qItem.key)

    # Store headers on database
    let nHdrs = buddy.headersStashOnDisk(
                  qItem.data.revHdrs, qItem.data.peerID, info).valueOr:
      ctx.headersUnprocAppend(minNum, maxNum)
      switchPeer = true
      break

    nStashed += nHdrs
    nUnstaged.inc
    # End while loop

  if 0 < nStashed:
    chronicles.info "Headers stashed", nStashed,
      nUnpoc=ctx.nUnprocStr(),
      nStagedQ=ctx.hdr.staged.len,
      nUnstaged,
      eta=ctx.pool.syncEta.avg.toStr,
      base=ctx.chain.baseNumber.bnStr,
      head=ctx.chain.latestNumber.bnStr,
      target=ctx.hdrCache.head.bnStr,
      nSyncPeers=ctx.nSyncPeers()

  elif switchPeer or 0 < ctx.hdr.staged.len:
    trace info & ": no headers processed", peer, nStashed,
      nStagedQ=ctx.hdr.staged.len, D=ctx.hdrCache.antecedent.bnStr,
      nSyncPeers=ctx.nSyncPeers(), switchPeer

  not switchPeer

# --------------

proc headersStagedReorg*(ctx: BeaconCtxRef; info: static[string]) =
  ## Some pool mode intervention.
  ##
  if ctx.pool.syncState in {headersCancel,headersFinish}:
    trace info & ": Flushing header queues",
      nUnproc=ctx.headersUnprocTotal(), nStagedQ=ctx.hdr.staged.len

    ctx.headersUnprocClear() # clears `unprocessed` and `borrowed` list
    ctx.headersStagedQueueClear()
    ctx.subState.reset

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
