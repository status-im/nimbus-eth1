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
  ./[headers_unproc, update]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headerStagedUpdateTarget*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) {.async: (raises: []).} =
  ## Fetch finalised beacon header if there is an update available
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if ctx.layout.lastState == idleSyncState and
     ctx.target.final == 0 and
     ctx.target.finalHash != zeroHash32 and
     not ctx.target.locked:
    const iv = BnRange.new(1u,1u) # dummy interval

    ctx.target.locked = true
    let rc = await buddy.headersFetchReversed(iv, ctx.target.finalHash, info)
    ctx.target.locked = false

    if rc.isOk:
      let hash = rlp.encode(rc.value[0]).keccak256
      if hash != ctx.target.finalHash:
        # Oops
        buddy.ctrl.zombie = true
        debug info & ": finalised header hash mismatch", peer, hash,
          expected=ctx.target.finalHash
      else:
        ctx.updateFinalBlockHeader(rc.value[0], ctx.target.finalHash, info)


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
        lhc = (ref LinkedHChain)()

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



proc headersStagedProcess*(ctx: BeaconCtxRef; info: static[string]): int =
  ## Store headers from the `staged` queue onto the header chain cache.
  ##
  var
    nHeadersProcessed = 0                                   # statistics

  while true:

    # Fetch list with largest block numbers
    let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
      break # all done

    let
      dangling = ctx.layout.dangling
      iv = BnRange.new(qItem.key - qItem.data.revHdrs.len.uint64 + 1, qItem.key)
    if iv.maxPt+1 < dangling:
      debug info & ": gap detected, serialisation postponed", iv,
        D=dangling.bnStr, nHeadersProcessed, nStaged=ctx.hdr.staged.len,
        qItem=qItem.data.bnStr
      break # there is a gap -- come back later

    # Overlap must not happen
    if iv.maxPt+1 != dangling:
      raiseAssert info & ": Overlap iv=" & $iv & " D=" & dangling.bnStr

    # Process item from `staged` queue. So it is not needed in the list,
    # anymore.
    discard ctx.hdr.staged.delete(iv.maxPt)

    let dglParHash =
      ctx.hdrCache.fcHeaderGetParentHash(dangling).expect "parentHash"

    if qItem.data.hash != dglParHash:
      # Discard wrong chain and merge back the range into the `unproc` list.
      ctx.headersUnprocAppend(iv)
      debug info & ": discarding staged header list", iv,
        D=dangling.bnStr, nHeadersProcessed, nDiscarded=qItem.data.revHdrs.len,
        qItem=qItem.data.bnStr
      break

    # Store headers on database
    ctx.hdrCache.fcHeaderPut(qItem.data.revHdrs).isOkOr:
      ctx.headersUnprocAppend(iv)
      debug info & ": discarding staged header list", iv,
        D=dangling.bnStr, nHeadersProcessed, nDiscarded=qItem.data.revHdrs.len,
        `error`=error, qItem=qItem.data.bnStr
      break
    ctx.layout.dangling = iv.minPt

    nHeadersProcessed += qItem.data.revHdrs.len # count headers
    # End while loop

  if headersStagedQueueLengthLwm < ctx.hdr.staged.len:
    ctx.poolMode = true

  debug info & ": staged headers stored on disk",
    nStagedLists=ctx.hdr.staged.len, nHeadersProcessed

  nHeadersProcessed



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
