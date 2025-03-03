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
  ./headers_staged/staged_collect,
  ./headers_unproc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headersStagedCollect*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ): Future[bool] {.async: (raises: []).} =
  ## Collect headers and either stash them on the header chain cache directly,
  ## or stage then on the header queue to get them serialised, later. The
  ## header queue serialisation is needed in case of several peers fetching
  ## and processing headers concurrently.
  ##
  ## If there are headers left to process, tThis function will always stages
  ## a header list record on the header queue for serialisation, and returns
  ## `true`.
  ##
  ## Otherwise the function returns `false` if there are no headers left to be
  ## processed.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer

  if ctx.headersUnprocIsEmpty():
    return false                                     # no action
  var
    nDeterministic = 0u64                            # statistics, to be updated
    nOpportunistic = 0                               # ditto

  block fetchHeadersBody:

    # Start deterministically, explicitely fetch/append by parent hash
    while ctx.layout.dangling <= ctx.headersUnprocAvailTop() + 1:
      let
        # Reserve the full range of block numbers so they can be appended in a
        # row. This avoid some fragmentation when header chains are stashed by
        # multiple peers, i.e. they interleave peer task-wise.
        iv = ctx.headersUnprocFetch(nFetchHeadersBatch).valueOr:
          break fetchHeadersBody                     # done, exit this function

        # Get parent hash from the last stored header
        parent = ctx.hdrCache.fcHeaderGetParentHash(ctx.layout.dangling)
                             .expect "parentHash"

        # Fetch headers and store them on the header chain cache,
        # get returned the last unprocessed block number
        bottom = await buddy.collectAndStashOnDiskCache(iv, parent, info)

      nDeterministic += (iv.maxPt - bottom)          # statistics

      # Commit processed block numbers
      if iv.minPt <= bottom:
        ctx.headersUnprocCommit(iv,iv.minPt,bottom)  # partial success only
        break fetchHeadersBody                       # done, exit this function

      ctx.headersUnprocCommit(iv)                    # all headers processed
      # End while: `collectAndStashOnDiskCache()`

    trace info & ": deterministic fetch done", peer,
      unprocTop=ctx.headersUnprocAvailTop.bnStr, D=ctx.layout.dangling.bnStr,
      nDeterministic, nStaged=ctx.hdr.staged.len

    # Continue opportunistic by block number, the fetched headers need to be
    # staged and checked/serialised later
    block:
      let
        # Comment see deterministic case
        iv = ctx.headersUnprocFetch(nFetchHeadersBatch).valueOr:
          break fetchHeadersBody                     # done, exit this function

        # This record will accumulate the fetched headers. It must be on the
        # heap so that `async` can capture that properly.
        lhc = (ref LinkedHChain)(peerID: buddy.peerID)

        # Fetch headers and fill up the headers list of `lhc`,
        # get returned the last unprocessed block number
        bottom = await buddy.collectAndStageOnMemQueue(iv, lhc, info)

      # Store `lhc` chain on the `staged` queue if there is any
      if 0 < lhc.revHdrs.len:
        let qItem = ctx.hdr.staged.insert(iv.maxPt).valueOr:
          raiseAssert info & ": duplicate key on staged queue iv=" & $iv
        qItem.data = lhc[]

      nOpportunistic = lhc.revHdrs.len               # statistics

      # Commit processed block numbers
      if iv.minPt <= bottom:
        ctx.headersUnprocCommit(iv,iv.minPt,bottom)  # partial success only
        break fetchHeadersBody                       # done, exit this function

      ctx.headersUnprocCommit(iv)                    # all headers processed
      # End inner block

    # End block: `fetchHeadersBody`

  # The cache `antecedent` must match variable `D` (aka dangling)
  doAssert ctx.hdrCache.fcHeaderAntecedent().number <= ctx.layout.dangling

  if nDeterministic == 0 and nOpportunistic == 0:
    return false

  info "Downloaded headers", unprocTop=ctx.headersUnprocAvailTop.bnStr,
    nDeterministic, nOpportunistic, nStaged=ctx.hdr.staged.len,
    nSyncPeers=ctx.pool.nBuddies, reorgReq=ctx.poolMode

  return true



proc headersStagedProcess*(buddy: BeaconBuddyRef; info: static[string]) =
  ## Store headers from the `staged` queue onto the header chain cache.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if ctx.hdr.staged.len == 0:
    return                                                  # avoids logging

  var
    nProcessed = 0                                          # statistics

  while true:

    # Fetch list with largest block numbers
    let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
      break # all done

    doAssert qItem.key == qItem.data.revHdrs[0].number

    let
      minNum = qItem.data.revHdrs[^1].number
      maxNum = qItem.data.revHdrs[0].number
      dangling = ctx.layout.dangling
    if maxNum + 1 < dangling:
      debug info & ": gap, serialisation postponed", peer,
        qItem=qItem.data.bnStr, D=dangling.bnStr, nProcessed,
        nStaged=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies
      return # there is a gap -- come back later

    # Overlap must not happen
    if maxNum+1 != dangling:
      raiseAssert info & ": Overlap" &
        " qItem=" & qItem.data.bnStr & " D=" & dangling.bnStr

    # Process item from `staged` queue. So it is not needed in the list,
    # anymore.
    discard ctx.hdr.staged.delete(qItem.key)

    # Store headers on database
    ctx.hdrCache.fcHeaderPut(qItem.data.revHdrs).isOkOr:
      ctx.headersUnprocAppend(minNum, maxNum)

      # Error mark buddy that produced that unusable headers list
      buddy.incHdrProcErrors qItem.data.peerID

      debug info & ": discarding staged header list", peer,
        qItem=qItem.data.bnStr, D=dangling.bnStr, nProcessed,
        nDiscarded=qItem.data.revHdrs.len, nSyncPeers=ctx.pool.nBuddies,
        `error`=error
      return

    # Update location of insertion, this is typically the same as the
    # `antecedent` from the header chain cache.
    ctx.layout.dangling = minNum

    nProcessed += qItem.data.revHdrs.len # count headers
    # End while loop

  if headersStagedQueueLengthLwm < ctx.hdr.staged.len:
    ctx.poolMode = true

  debug info & ": headers serialised and stored", peer,
    D=ctx.layout.dangling.bnStr, nProcessed,
    nStagedLists=ctx.hdr.staged.len, nSyncPeers=ctx.pool.nBuddies,
    reorgReq=ctx.poolMode



proc headersStagedReorg*(ctx: BeaconCtxRef; info: static[string]) =
  ## Some pool mode intervention. The effect is that all concurrent peers
  ## finish up their current work and run this function here (which might
  ## do nothing.) This stopping should be enough in most cases to re-organise
  ## when re-starting concurrently, again.
  ##
  ## Only when the staged list gets too big it will be cleared to be re-filled
  ## again. In therory, this might happen on a really slow lead actor
  ## (downloading deterministically by hashes) and many fast opportunistic
  ## actors filling the staged queue.
  ##
  doAssert ctx.headersBorrowedIsEmpty()

  if ctx.hdr.staged.len == 0:
    # nothing to do
    return

  # Update counter
  ctx.pool.nReorg.inc

  let nStaged = ctx.hdr.staged.len
  if headersStagedQueueLengthHwm < nStaged:
    trace info & ": hwm reached, flushing staged queue",
      nStaged, max=headersStagedQueueLengthLwm

    # Remove the leading `1 + nStaged - headersStagedQueueLengthLwm` entries
    # from list so that the upper `headersStagedQueueLengthLwm-1` entries
    # remain.
    for _ in 0 .. nStaged - headersStagedQueueLengthLwm:
      let
        qItem = ctx.hdr.staged.ge(BlockNumber 0).expect "valid record"
        key = qItem.key
        nHeaders = qItem.data.revHdrs.len.uint64
      ctx.headersUnprocAppend(key - nHeaders + 1, key)
      discard ctx.hdr.staged.delete key

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
