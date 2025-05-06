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
  pkg/stew/[interval_set, sorted_set],
  ../worker_desc,
  ./headers_staged/[headers, staged_collect],
  ./headers_staged/staged_debug,
  ./headers_unproc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func headersStagedCollectOk*(buddy: BeaconBuddyRef): bool =
  ## Helper for `worker.nim`, etc.
  if buddy.ctrl.running:
    let ctx = buddy.ctx
    if 0 < ctx.headersUnprocAvail() and
       not ctx.collectModeStopped():
      return true
  false

proc headersStagedCollect*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Collect headers and either stash them on the header chain cache directly,
  ## or stage then on the header queue to get them serialised, later. The
  ## header queue serialisation is needed in case of several peers fetching
  ## and processing headers concurrently.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if ctx.headersUnprocIsEmpty() or
     ctx.hdrCache.state != collecting:
    debug info & ": nothing to do", peer,
      unprocEmpty=ctx.headersUnprocIsEmpty(), nStaged=ctx.hdr.staged.len,
      ctrl=buddy.ctrl.state, cacheMode=ctx.hdrCache.state,
      syncState=ctx.pool.lastState, nSyncPeers=ctx.pool.nBuddies
    return                                           # no action
  var
    nDeterministic = 0u64                            # statistics, to be updated
    nOpportunistic = 0                               # ditto

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
      #    ------------------|                 unproc pool
      #              |-------|                 block interval to fetch next
      #                       |----------      already stored headers on cache
      #                      top
      #                    dangling
      #
      # After claiming the block interval that will be processed next for the
      # deterministic fetch, the situation for the new `top` would look like
      # ::
      #    ---------|                          unproc pool
      #              |-------|                 block interval to fetch next
      #                       |----------      already stored headers on cache
      #             top     dangling
      #
      # so any other peer arriving here will see a gap between `top` and
      # `dangling` which will lead them to fetch opportunistcally.
      if top < ctx.dangling.number:
        break

      # Throw away overlap (should not happen anyway)
      if ctx.dangling.number < top:
        discard ctx.headersUnprocFetch(top-ctx.dangling.number).expect("iv")

      let
        # Reserve the full range of block numbers so they can be appended in a
        # row. This avoid some fragmentation when header chains are stashed by
        # multiple peers, i.e. they interleave peer task-wise.
        iv = ctx.headersUnprocFetch(nFetchHeadersBatch).valueOr:
          break fetchHeadersBody                     # done, exit this function

        # Get parent hash from the most senior stored header
        parent = ctx.dangling.parentHash

        # Fetch headers and store them on the header chain cache. The function
        # returns the last unprocessed block number
        bottom = await buddy.collectAndStashOnDiskCache(iv, parent, info)

      # Check whether there were some headers fetched at all
      if bottom < iv.maxPt:
        nDeterministic += (iv.maxPt - bottom)        # statistics
        ctx.pool.seenData = true                     # header data exist

      # Job might have been cancelled or completed while downloading headers.
      # If so, no more bookkeeping of headers must take place. The *books*
      # might have been reset and prepared for the next stage.
      if ctx.collectModeStopped():
        trace info & ": deterministic headers fetch stopped", peer, iv,
          bottom=bottom.bnStr, nDeterministic, ctrl=buddy.ctrl.state,
          syncState=ctx.pool.lastState, cacheMode=ctx.hdrCache.state,
          hdr=ctx.hdr.bnStr
        break fetchHeadersBody                       # done, exit this function

      # Commit partially processed block numbers
      if iv.minPt <= bottom:
        ctx.headersUnprocCommit(iv,iv.minPt,bottom)  # partial success only
        break fetchHeadersBody                       # done, exit this function

      ctx.headersUnprocCommit(iv)                    # all headers processed

      debug info & ": deterministic headers fetch count", peer,
        unprocTop=ctx.headersUnprocAvailTop.bnStr, D=ctx.dangling.bnStr,
        nDeterministic, nStaged=ctx.hdr.staged.len, ctrl=buddy.ctrl.state

      # Buddy might have been cancelled while downloading headers.
      if buddy.ctrl.stopped:
        break fetchHeadersBody

      # End while: `collectAndStashOnDiskCache()`

    # Continue opportunistically fetching by block number rather than hash. The
    # fetched headers need to be staged and checked/serialised later.
    if ctx.hdr.staged.len < headersStagedQueueLengthHwm:
      doAssert ctx.hdr.verify()

      let
        # Comment see deterministic case
        iv = ctx.headersUnprocFetch(nFetchHeadersBatch).valueOr:
          break fetchHeadersBody                     # done, exit this function

        # This record will accumulate the fetched headers. It must be on the
        # heap so that `async` can capture that properly.
        lhc = (ref LinkedHChain)(peerID: buddy.peerID)

        # Fetch headers and fill up the headers list of `lhc`. The function
        # returns the last unprocessed block number.
        bottom = await buddy.collectAndStageOnMemQueue(iv, lhc, info)

      nOpportunistic = lhc.revHdrs.len               # statistics

      # Job might have been cancelled or completed while downloading headers.
      # If so, no more bookkeeping of headers must take place. The *books*
      # might have been reset and prepared for the next stage.
      if ctx.collectModeStopped():
        trace info & ": staging headers fetch stopped", peer, iv,
          bottom=bottom.bnStr, nDeterministic, ctrl=buddy.ctrl.state,
          syncState=ctx.pool.lastState, cacheMode=ctx.hdrCache.state,
          hdr=ctx.hdr.bnStr
        break fetchHeadersBody                       # done, exit this function

      # Store `lhc` chain on the `staged` queue if there is any
      if 0 < lhc.revHdrs.len:
        let qItem = ctx.hdr.staged.insert(iv.maxPt).valueOr:
          raiseAssert info & ": duplicate key on staged queue iv=" & $iv
        qItem.data = lhc[]

      # Commit processed block numbers
      if iv.minPt <= bottom:
        ctx.headersUnprocCommit(iv,iv.minPt,bottom)  # partial success only
        break fetchHeadersBody                       # done, exit this function

      ctx.headersUnprocCommit(iv)                    # all headers processed
      # End inner block

    # End block: `fetchHeadersBody`

  doAssert ctx.hdr.verify()

  let nHeaders = nDeterministic + nOpportunistic.uint64
  if nHeaders == 0:
    if not ctx.pool.seenData:
      # Collect peer for detecting cul-de-sac syncing (i.e. non-existing
      # block chain or similar.)
      ctx.pool.failedPeers.incl buddy.peerID

      debug info & ": no headers yet", peer, ctrl=buddy.ctrl.state,
        cacheMode=ctx.hdrCache.state, syncState=ctx.pool.lastState,
        failedPeers=ctx.pool.failedPeers.len, hdrErrors=buddy.hdrErrors
    return

  info "Downloaded headers",
    unprocTop=(if ctx.collectModeStopped(): "n/a"
               else: ctx.headersUnprocAvailTop.bnStr),
    nHeaders, nStaged=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies



proc headersStagedProcess*(buddy: BeaconBuddyRef; info: static[string]): bool =
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
    return true                                             # avoids logging

  var
    nProcessed = 0                                          # statistics
    switchPeer = false                                      # for return code

  while ctx.hdrCache.state == collecting:

    # Fetch list with largest block numbers
    let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
      break # all done

    let
      minNum = qItem.data.revHdrs[^1].number
      maxNum = qItem.data.revHdrs[0].number
      dangling = ctx.dangling.number
    if maxNum + 1 < dangling:
      debug info & ": gap, serialisation postponed", peer,
        qItem=qItem.data.bnStr, D=dangling.bnStr, nProcessed,
        nStaged=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies
      switchPeer = true # there is a gap -- come back later
      break

    # Overlap must not happen
    if maxNum+1 != dangling:
      raiseAssert info & ": Overlap" &
        " qItem=" & qItem.data.bnStr & " D=" & dangling.bnStr

    # Process item from `staged` queue. So it is not needed in the list,
    # anymore.
    discard ctx.hdr.staged.delete(qItem.key)

    # Store headers on database
    ctx.hdrCache.put(qItem.data.revHdrs).isOkOr:
      ctx.headersUnprocAppend(minNum, maxNum)

      # Error mark buddy that produced that unusable headers list
      buddy.incHdrProcErrors qItem.data.peerID

      debug info & ": discarding staged header list", peer,
        qItem=qItem.data.bnStr, D=ctx.dangling.bnStr, nProcessed,
        nDiscarded=qItem.data.revHdrs.len, nSyncPeers=ctx.pool.nBuddies,
        `error`=error
      switchPeer = true
      break

    # Antecedent `dangling` of the header cache might not be at `revHdrs[^1]`.
    let revHdrsLen = maxNum - ctx.dangling.number + 1

    nProcessed += revHdrsLen.int # count headers

    # End while loop

  debug info & ": headers serialised and stored", peer, D=ctx.dangling.bnStr,
    nProcessed, nStaged=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies,
    switchPeer

  not switchPeer


proc headersStagedReorg*(ctx: BeaconCtxRef; info: static[string]) =
  ## Some pool mode intervention. The effect is that all concurrent peers
  ## finish up their current work and run this function here (which might
  ## do nothing.) Pool mode is used to sync peers, e.g. for a forced state
  ## change.
  ##
  doAssert ctx.headersBorrowedIsEmpty()

  if ctx.hdr.staged.len == 0:
    # nothing to do
    return

  # Update counter
  ctx.pool.nReorg.inc

  # Check for cancel request
  if ctx.pool.lastState == cancelHeaders:
    # Reset header queues
    debug info & ": Flushing header queues", nUnproc=ctx.headersUnprocTotal(),
      nStaged=ctx.hdr.staged.len, nReorg=ctx.pool.nReorg

    ctx.headersUnprocClear()
    ctx.hdr.staged.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
