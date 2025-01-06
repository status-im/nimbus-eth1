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
  std/strutils,
  pkg/[chronicles, chronos],
  pkg/eth/[common, p2p],
  pkg/stew/[interval_set, sorted_set],
  ../../../common,
  ../worker_desc,
  ./update/metrics,
  ./headers_staged/[headers, linked_hchain],
  "."/[headers_unproc, update]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchAndCheck(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    lhc: ref LinkedHChain; # update in place
    info: static[string];
      ): Future[bool] {.async: (raises: []).} =
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
  if not revHeaders.extendLinkedHChain(buddy, ivReq.maxPt, lhc):
    buddy.only.nHdrProcErrors.inc
    return false

  return true

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
    topLink = if isOpportunistic: EMPTY_ROOT_HASH
              else: ctx.dbHeaderParentHash(ctx.layout.dangling).expect "Hash32"

  var
    # This value is used for splitting the interval `iv` into
    # `[iv.minPt, somePt] + [somePt+1, ivTop] + already-collected` where the
    # middle interval `[somePt+1, ivTop]` will be fetched from the network.
    ivTop = iv.maxPt

    # This record will accumulate the fetched headers. It must be on the heap
    # so that `async` can capture that properly.
    lhc = (ref LinkedHChain)(parentHash: topLink)

    # Flag, not to reset error count
    haveError = false

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
      haveError = true

      # Throw away opportunistic data (or first time header fetch.) Keep
      # other data for a partially assembled list.
      if isOpportunistic or nLhcHeaders == 0:
        if ((0 < buddy.only.nHdrRespErrors or
             0 < buddy.only.nHdrProcErrors) and buddy.ctrl.stopped) or
           fetchHeadersReqErrThresholdCount < buddy.only.nHdrRespErrors or
           fetchHeadersProcessErrThresholdCount < buddy.only.nHdrProcErrors:
          # Make sure that this peer does not immediately reconnect
          buddy.ctrl.zombie = true
        debug info & ": current header list discarded", peer, iv, ivReq,
          isOpportunistic, ctrl=buddy.ctrl.state, hdrErrors=buddy.hdrErrors
        ctx.headersUnprocCommit(iv.len, iv)
        # At this stage allow a task switch so that some other peer might try
        # to work on the currently returned interval.
        try: await sleepAsync asyncThreadSwitchTimeSlot
        except CancelledError: discard
        return false

      # So it is deterministic and there were some headers downloaded already.
      # Turn back unused data and proceed with staging.
      debug info & ": partially failed", peer, iv, ivReq,
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

  # Reset header process errors (not too many consecutive failures this time)
  if not haveError:
    buddy.only.nHdrProcErrors = 0

  info "Downloaded a list of headers", peer, topBlock=iv.maxPt.bnStr,
    nHeaders=lhc.revHdrs.len, nStaged=ctx.hdr.staged.len, isOpportunistic,
    ctrl=buddy.ctrl.state, hdrErrors=buddy.hdrErrors

  return true


proc headersStagedProcess*(ctx: BeaconCtxRef; info: static[string]): int =
  ## Store/insert stashed chains from the `staged` queue into the linked
  ## chains layout and the persistent tables. The function returns the number
  ## of records processed and saved.
  while true:
    # Fetch list with largest block numbers
    let qItem = ctx.hdr.staged.le(high BlockNumber).valueOr:
      break # all done

    let
      dangling = ctx.layout.dangling
      iv = BnRange.new(qItem.key - qItem.data.revHdrs.len.uint64 + 1, qItem.key)
    if iv.maxPt+1 < dangling:
      debug info & ": there is a gap", iv, D=dangling.bnStr, nStashed=result
      break # there is a gap -- come back later

    # Overlap must not happen
    if iv.maxPt+1 != dangling:
      raiseAssert info & ": Overlap iv=" & $iv & " D=" & dangling.bnStr

    # Process item from `staged` queue. So it is not needed in the list,
    # anymore.
    discard ctx.hdr.staged.delete(iv.maxPt)

    # Update, so it can be followed nicely
    ctx.updateMetrics()

    if qItem.data.hash != ctx.dbHeaderParentHash(dangling).expect "Hash32":
      # Discard wrong chain and merge back the range into the `unproc` list.
      ctx.headersUnprocCommit(0,iv)
      debug info & ": discarding staged header list", iv, D=dangling.bnStr,
        nStashed=result, nDiscarded=qItem.data.revHdrs.len
      break

    # Store headers on database
    ctx.dbHeadersStash(iv.minPt, qItem.data.revHdrs, info)
    ctx.layout.dangling = iv.minPt
    ctx.dbStoreSyncStateLayout info

    result += qItem.data.revHdrs.len # count headers

  debug info & ": stashed consecutive headers",
    nListsLeft=ctx.hdr.staged.len, nStashed=result

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
