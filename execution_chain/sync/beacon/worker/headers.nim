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
  ../worker_desc,
  ./headers/[headers_headers, headers_helpers, headers_queue, headers_unproc]

export
  headers_queue, headers_unproc

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
      nStored {.inject.} = 0u64                      # statistics, to be updated
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
        # `dangling` which will lead them to fetch opportunistcally.
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
        let dTop = ctx.hdrCache.antecedent.number    # current antecedent
        if not buddy.headersStashOnDisk(rev, buddy.peerID, info):
          break fetchHeadersBody                     # error => exit block

        let dBottom = ctx.hdrCache.antecedent.number # update new antecedent
        nStored += (dTop - dBottom)                  # statistics

        if dBottom == dTop:
          break fetchHeadersBody                     # nothing achieved

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
          qItem = ctx.hdr.staged.insert(key).valueOr:
            raiseAssert info & ": duplicate key on staged queue" &
              " iv=" & (rc.value[^1].number,key).bnStr
        qItem.data.revHdrs = rc.value
        qItem.data.peerID = buddy.peerID

        nQueued = rc.value.len                       # statistics
        # End if

      # End block: `fetchHeadersBody`

    if nStored == 0 and nQueued == 0:
      if not ctx.pool.seenData and
         buddy.peerID notin ctx.pool.failedPeers and
         buddy.ctrl.stopped:
        # Collect peer for detecting cul-de-sac syncing (i.e. non-existing
        # block chain or similar.)
        ctx.pool.failedPeers.incl buddy.peerID

        debug info & ": no headers yet (failed peer)", peer,
          failedPeers=ctx.pool.failedPeers.len,
          syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors
      break body                                     # return

    chronicles.info "Queued/staged or DB/stored headers",
      unprocTop=(if ctx.hdrSessionStopped(): "n/a"
                 else: ctx.headersUnprocAvailTop.bnStr),
      nQueued, nStored, nStagedQ=ctx.hdr.staged.len,
      nSyncPeers=ctx.pool.nBuddies

  discard

# --------------

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
    return false                                            # switch peer

  var
    nStored = 0u64                                           # statistics
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
      trace info & ": gap, serialisation postponed", peer,
        qItem=qItem.data.revHdrs.bnStr, D=dangling.bnStr, nStored,
        nStagedQ=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies
      switchPeer = true # there is a gap -- come back later
      break

    # Remove from queue
    discard ctx.hdr.staged.delete(qItem.key)

    # Store headers on database
    if not buddy.headersStashOnDisk(
                   qItem.data.revHdrs, qItem.data.peerID, info):
      ctx.headersUnprocAppend(minNum, maxNum)
      switchPeer = true
      break

    # Antecedent of the header cache might not be at `revHdrs[^1]`.
    nStored += (maxNum - ctx.hdrCache.antecedent.number + 1) # count headers
    # End while loop

  if 0 < nStored:
    info "Headers serialised and stored", D=ctx.hdrCache.antecedent.bnStr,
      nStored, nStagedQ=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies,
      switchPeer

  elif 0 < ctx.hdr.staged.len and not switchPeer:
    trace info & ": no headers processed", peer,
      D=ctx.hdrCache.antecedent.bnStr, nStagedQ=ctx.hdr.staged.len,
      nSyncPeers=ctx.pool.nBuddies

  not switchPeer

# --------------

proc headersStagedReorg*(ctx: BeaconCtxRef; info: static[string]) =
  ## Some pool mode intervention.
  ##
  if ctx.pool.lastState in {headersCancel,headersFinish}:
    trace info & ": Flushing header queues",
      nUnproc=ctx.headersUnprocTotal(), nStagedQ=ctx.hdr.staged.len

    ctx.headersUnprocClear() # clears `unprocessed` and `borrowed` list
    ctx.hdr.staged.clear()
    ctx.subState.reset

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
