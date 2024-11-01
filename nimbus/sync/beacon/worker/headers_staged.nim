# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  pkg/[chronicles, chronos],
  pkg/eth/[common, p2p],
  pkg/stew/[interval_set, sorted_set],
  ../../../common,
  ../worker_desc,
  ./update/metrics,
  ./headers_staged/[headers, linked_hchain],
  ./headers_unproc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchAndCheck(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    lhc: ref LinkedHChain; # update in place
    info: static[string];
      ): Future[bool] {.async.} =
  ## Collect single header chain from the peer and stash it on the `staged`
  ## queue. Returns the length of the stashed chain of headers.
  ##
  # Fetch headers for this range of block numbers
  let revHeaders = block:
    let rc = await buddy.headersFetchReversed(ivReq, lhc.parentHash, info)
    if rc.isErr:
      return false
    rc.value

  # While assembling a `LinkedHChainRef`, verify that the `revHeaders` list
  # was sound, i.e. contiguous, linked, etc.
  if not revHeaders.extendLinkedHChain(buddy, ivReq.maxPt, lhc, info):
    return false

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headerStagedUpdateTarget*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ) {.async.} =
  ## Fetch finalised beacon header if there is an update available
  let
    ctx = buddy.ctx
    peer = buddy.peer
  if not ctx.layout.headLocked and
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
        trace info & ": finalised header hash mismatch", peer, hash,
          expected=ctx.target.finalHash
      else:
        let final = rc.value[0].number
        if final < ctx.chain.baseNumber():
          trace info & ": finalised number too low", peer,
            B=ctx.chain.baseNumber.bnStr, finalised=rc.value[0].number.bnStr
        else:
          ctx.target.final = final

          # Update, so it can be followed nicely
          ctx.updateMetrics()


proc headersStagedCollect*(
    buddy: BeaconBuddyRef;
    info: static[string];
      ): Future[bool] {.async.} =
  ## Collect a batch of chained headers totalling to at most `nHeaders`
  ## headers. Fetch the headers from the the peer and stash it blockwise on
  ## the `staged` queue. The function returns `true` it stashed a header
  ## chains record on `staged` queue.
  ##
  ## This function segments the `nHeaders` length into smaller pieces of at
  ## most `nFetchHeadersRequest` chunks ans fetch these chunks from the
  ## network. Where possible, hashes are used to address the headers to be
  ## fetched. Otherwise the system works opportunistically using block
  ## numbers for fetching, stashing them away to be verified later when
  ## appropriate.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer
    uTop = ctx.headersUnprocTop()

  if uTop == 0:
    # Nothing to do
    return false

  let
    # Reserve the full range of block numbers so they can be appended in a row.
    # This avoid some fragmentation when header chains are stashed by multiple
    # peers, i.e. they interleave peer-wise.
    iv = ctx.headersUnprocFetch(nFetchHeadersBatch).expect "valid interval"

    # Check for top header hash. If the range to fetch directly joins below
    # the top level linked chain `[D,H]`, then there is the hash available for
    # the top level header to fetch. Otherwise -- with multi-peer mode -- the
    # range of headers is fetched opportunistically using block numbers only.
    isOpportunistic = uTop + 1 < ctx.layout.dangling

    # Parent hash for `lhc` below
    topLink = (if isOpportunistic: EMPTY_ROOT_HASH
               else: ctx.layout.danglingParent)
  var
    # This value is used for splitting the interval `iv` into
    # `[iv.minPt, somePt] + [somePt+1, ivTop] + already-collected` where the
    # middle interval `[somePt+1, ivTop]` will be fetched from the network.
    ivTop = iv.maxPt

    # This record will accumulate the fetched headers. It must be on the heap
    # so that `async` can capture that properly.
    lhc = (ref LinkedHChain)(parentHash: topLink)

  while true:
    # Extract top range interval and fetch/stage it
    let
      ivReqMin = if ivTop + 1 <= iv.minPt + nFetchHeadersRequest: iv.minPt
                 else: ivTop - nFetchHeadersRequest + 1

      # Request interval
      ivReq = BnRange.new(ivReqMin, ivTop)

      # Current length of the headers queue. This is used to calculate the
      # response length from the network.
      nLhcHeaders = lhc.revHdrs.len

    # Fetch and extend chain record
    if not await buddy.fetchAndCheck(ivReq, lhc, info):

      # Throw away opportunistic data (or first time header fetch.) Turn back
      # unused data.
      if isOpportunistic or nLhcHeaders == 0:
        if 0 < buddy.only.nHdrRespErrors and buddy.ctrl.stopped:
          # Make sure that this peer does not immediately reconnect
          buddy.ctrl.zombie = true
        trace info & ": completely failed", peer, iv, ivReq, isOpportunistic,
          ctrl=buddy.ctrl.state, nRespErrors=buddy.only.nHdrRespErrors
        ctx.headersUnprocCommit(iv.len, iv)
        # At this stage allow a task switch so that some other peer might try
        # to work on the currently returned interval.
        await sleepAsync asyncThreadSwitchTimeSlot
        return false

      # So it is deterministic and there were some headers downloaded already.
      # Turn back unused data and proceed with staging.
      trace info & ": partially failed", peer, iv, ivReq,
        unused=BnRange.new(iv.minPt,ivTop), isOpportunistic
      # There is some left over to store back
      ctx.headersUnprocCommit(iv.len, iv.minPt, ivTop)
      break

    # Update remaining interval
    let ivRespLen = lhc.revHdrs.len - nLhcHeaders
    if ivTop < iv.minPt + ivRespLen.uint64:
      # All collected
      ctx.headersUnprocCommit(iv.len)
      break

    ivTop -= ivRespLen.uint64 # will mostly result into `ivReq.minPt-1`

    if buddy.ctrl.stopped:
      # There is some left over to store back. And `iv.minPt <= ivTop` because
      # of the check against `ivRespLen` above.
      ctx.headersUnprocCommit(iv.len, iv.minPt, ivTop)
      break

  # Store `lhc` chain on the `staged` queue
  let qItem = ctx.hdr.staged.insert(iv.maxPt).valueOr:
    raiseAssert info & ": duplicate key on staged queue iv=" & $iv
  qItem.data = lhc[]

  trace info & ": staged headers", peer,
    topBlock=iv.maxPt.bnStr, nHeaders=lhc.revHdrs.len,
    nStaged=ctx.hdr.staged.len, isOpportunistic, ctrl=buddy.ctrl.state

  return true


proc headersStagedProcess*(ctx: BeaconCtxRef; info: static[string]): int =
  ## Store/insert stashed chains from the `staged` queue into the linked
  ## chains layout and the persistent tables. The function returns the number
  ## of records processed and saved.
  while true:
    # Fetch largest block
    let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
      trace info & ": no staged headers", error=error
      break # all done

    let
      dangling = ctx.layout.dangling
      iv = BnRange.new(qItem.key - qItem.data.revHdrs.len.uint64 + 1, qItem.key)
    if iv.maxPt+1 < dangling:
      trace info & ": there is a gap", iv, D=dangling.bnStr, nSaved=result
      break # there is a gap -- come back later

    # Overlap must not happen
    if iv.maxPt+1 != dangling:
      raiseAssert info & ": Overlap iv=" & $iv & " D=" & dangling.bnStr

    # Process item from `staged` queue. So it is not needed in the list,
    # anymore.
    discard ctx.hdr.staged.delete(iv.maxPt)

    # Update, so it can be followed nicely
    ctx.updateMetrics()

    if qItem.data.hash != ctx.layout.danglingParent:
      # Discard wrong chain and merge back the range into the `unproc` list.
      ctx.headersUnprocCommit(0,iv)
      trace info & ": discarding staged record",
        iv, D=dangling.bnStr, lap=result
      break

    # Store headers on database
    ctx.dbStashHeaders(iv.minPt, qItem.data.revHdrs, info)
    ctx.layout.dangling = iv.minPt
    ctx.layout.danglingParent = qItem.data.parentHash
    ctx.dbStoreSyncStateLayout info

    result.inc # count records

  trace info & ": staged header lists saved",
    nStaged=ctx.hdr.staged.len, nSaved=result

  if headersStagedQueueLengthLwm < ctx.hdr.staged.len:
    ctx.poolMode = true

  # Update, so it can be followed nicely
  ctx.updateMetrics()


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
      ctx.headersUnprocCommit(0, key - nHeaders + 1, key)
      discard ctx.hdr.staged.delete key

    # Update, so it can be followed nicely
    ctx.updateMetrics()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
