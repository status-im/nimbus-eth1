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
  ./headers_staged/[headers, linked_hchain],
  ./headers_unproc

logScope:
  topics = "flare staged"

const
  extraTraceMessages = false
    ## Enabled additional logging noise

  verifyDataStructureOk = false
    ## Debugging mode

# ------------------------------------------------------------------------------
# Private debugging helpers
# ------------------------------------------------------------------------------

when verifyDataStructureOk:
  proc verifyStagedQueue(
      ctx: FlareCtxRef;
      info: static[string];
      multiMode = true;
        ) =
    ## Verify stated queue, check that recorded ranges are no unprocessed,
    ## and return the total sise if headers covered.
    ##
    # Walk queue items
    let walk = LinkedHChainQueueWalk.init(ctx.lhc.staged)
    defer: walk.destroy()

    var
      stTotal = 0u
      rc = walk.first()
      prv = BlockNumber(0)
    while rc.isOk:
      let
        key = rc.value.key
        nHeaders = rc.value.data.revHdrs.len.uint
        minPt = key - nHeaders + 1
        unproc = ctx.headersUnprocCovered(minPt, key)
      if 0 < unproc:
        raiseAssert info & ": unprocessed staged chain " &
          key.bnStr & " overlap=" & $unproc
      if minPt <= prv:
        raiseAssert info & ": overlapping staged chain " &
          key.bnStr & " prvKey=" & prv.bnStr & " overlap=" & $(prv - minPt + 1)
      stTotal += nHeaders
      prv = key
      rc = walk.next()

    # Check `staged[] <= L`
    if ctx.layout.least <= prv:
      raiseAssert info & ": staged top mismatch " &
        " L=" & $ctx.layout.least.bnStr & " stagedTop=" & prv.bnStr

    # Check `unprocessed{} <= L`
    let uTop = ctx.headersUnprocTop()
    if ctx.layout.least <= uTop:
      raiseAssert info & ": unproc top mismatch " &
        " L=" & $ctx.layout.least.bnStr & " unprocTop=" & uTop.bnStr

    # Check `staged[] + unprocessed{} == (B,L)`
    if not multiMode:
      let
        uTotal = ctx.headersUnprocTotal()
        both = stTotal + uTotal
        unfilled = if ctx.layout.least <= ctx.layout.base + 1: 0u
                   else: ctx.layout.least - ctx.layout.base - 1
      when extraTraceMessages:
        trace info & ": verify staged", stTotal, uTotal, both, unfilled
      if both != unfilled:
        raiseAssert info & ": staged/unproc mismatch " &
          " staged=" & $stTotal & " unproc=" & $uTotal & " exp-sum=" & $unfilled

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchAndCheck(
    buddy: FlareBuddyRef;
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
      when extraTraceMessages:
        trace info & ": fetch headers failed", peer=buddy.peer, ivReq,
          nRespErrors=buddy.only.nRespErrors
      return false
    rc.value

  # While assembling a `LinkedHChainRef`, verify that the `revHeaders` list
  # was sound, i.e. contiguous, linked, etc.
  if not revHeaders.extendLinkedHChain(buddy, ivReq.maxPt, lhc, info):
    when extraTraceMessages:
      trace info & ": fetched headers unusable", peer=buddy.peer, ivReq
    return false

  return true

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headersStagedCollect*(
    buddy: FlareBuddyRef;
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
    # the top level linked chain `L..F`, then there is the hash available for
    # the top level header to fetch. Otherwise -- with multi-peer mode -- the
    # range of headers is fetched opportunistically using block numbers only.
    isOpportunistic = uTop + 1 != ctx.layout.least

    # Parent hash for `lhc` below
    topLink = (if isOpportunistic: EMPTY_ROOT_HASH else: ctx.layout.leastParent)

  var
    # This value is used for splitting the interval `iv` into
    # `[iv.minPt, somePt] + [somePt+1, ivTop] + already-collected` where the
    # middle interval `[somePt+1, ivTop]` will be fetched from the network.
    ivTop = iv.maxPt

    # This record will accumulate the fetched headers. It must be on the heap
    # so that `async` can capture that properly.
    lhc = (ref LinkedHChain)(parentHash: topLink)

  while true:
    # Extract a top range interval and fetch/stage it
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
        if 0 < buddy.only.nRespErrors and buddy.ctrl.stopped:
          # Make sure that this peer does not immediately reconnect
          buddy.ctrl.zombie = true
        when extraTraceMessages:
          trace info & ": completely failed", peer, iv, ivReq, isOpportunistic,
            ctrl=buddy.ctrl.state, nRespErrors=buddy.only.nRespErrors
        ctx.headersUnprocMerge(iv)
        return false
      # So it is deterministic and there were some headers downloaded already.
      # Turn back unused data and proceed with staging.
      when extraTraceMessages:
        trace info & ": partially failed", peer, iv, ivReq,
          unused=BnRange.new(iv.minPt,ivTop), isOpportunistic
      ctx.headersUnprocMerge(iv.minPt, ivTop)
      break

    # Update remaining interval
    let ivRespLen = lhc.revHdrs.len - nLhcHeaders
    if ivTop <= iv.minPt + ivRespLen.uint or buddy.ctrl.stopped:
      break

    let newIvTop = ivTop - ivRespLen.uint # will mostly be `ivReq.minPt-1`
    when extraTraceMessages:
      trace info & ": collected range", peer, iv=BnRange.new(iv.minPt, ivTop),
        ivReq, ivResp=BnRange.new(newIvTop+1, ivReq.maxPt), ivRespLen,
        isOpportunistic
    ivTop = newIvTop

  # Store `lhcOpt` chain on the `staged` queue
  let qItem = ctx.lhc.staged.insert(iv.maxPt).valueOr:
    raiseAssert info & ": duplicate key on staged queue iv=" & $iv
  qItem.data = lhc[]

  when extraTraceMessages:
    trace info & ": staged headers", peer,
      iv=BnRange.new(iv.maxPt - lhc.revHdrs.len.uint + 1, iv.maxPt),
      nHeaders=lhc.revHdrs.len, nStaged=ctx.lhc.staged.len, isOpportunistic,
      ctrl=buddy.ctrl.state
  else:
    trace info & ": staged headers", peer,
      topBlock=iv.maxPt.bnStr, nHeaders=lhc.revHdrs.len,
      nStaged=ctx.lhc.staged.len, isOpportunistic, ctrl=buddy.ctrl.state

  return true


proc headersStagedProcess*(ctx: FlareCtxRef; info: static[string]): int =
  ## Store/insert stashed chains from the `staged` queue into the linked
  ## chains layout and the persistent tables. The function returns the number
  ## of records processed and saved.
  while true:
    # Fetch largest block
    let qItem = ctx.lhc.staged.le(high BlockNumber).valueOr:
      when not extraTraceMessages:
        trace info & ": no staged headers", error
      break # all done

    let
      least = ctx.layout.least # `L` from `README.md` (1) or `worker_desc`
      iv = BnRange.new(qItem.key - qItem.data.revHdrs.len.uint + 1, qItem.key)
    if iv.maxPt+1 < least:
      when extraTraceMessages:
        trace info & ": there is a gap", iv, L=least.bnStr, nSaved=result
      break # there is a gap -- come back later

    # Overlap must not happen
    if iv.maxPt+1 != least:
      raiseAssert info & ": Overlap iv=" & $iv & " L=" & least.bnStr

    # Process item from `staged` queue. So it is not needed in the list,
    # anymore.
    discard ctx.lhc.staged.delete(iv.maxPt)

    if qItem.data.hash != ctx.layout.leastParent:
      # Discard wrong chain and merge back the range into the `unproc` list.
      ctx.headersUnprocMerge(iv)
      when extraTraceMessages:
        trace info & ": discarding staged record", iv, L=least.bnStr, lap=result
      break

    # Store headers on database
    ctx.dbStashHeaders(iv.minPt, qItem.data.revHdrs)
    ctx.layout.least = iv.minPt
    ctx.layout.leastParent = qItem.data.parentHash
    let ok = ctx.dbStoreLinkedHChainsLayout()

    result.inc # count records

    when extraTraceMessages:
      trace info & ": staged record saved", iv, layout=ok, nSaved=result

  when not extraTraceMessages:
    trace info & ": staged records saved",
      nStaged=ctx.lhc.staged.len, nSaved=result

  if stagedQueueLengthLwm < ctx.lhc.staged.len:
    when extraTraceMessages:
      trace info & ": staged queue too large => reorg",
        nStaged=ctx.lhc.staged.len, max=stagedQueueLengthLwm
    ctx.poolMode = true


proc headersStagedReorg*(ctx: FlareCtxRef; info: static[string]) =
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
  # Update counter
  ctx.pool.nReorg.inc

  let nStaged = ctx.lhc.staged.len
  if stagedQueueLengthHwm < nStaged:
    trace info & ": hwm reached, flushing staged queue",
      nStaged, max=stagedQueueLengthLwm

    # Remove the leading `1 + nStaged - stagedQueueLengthLwm` entries from list
    # so that the upper `stagedQueueLengthLwm-1` entries remain.
    for _ in 0 .. nStaged - stagedQueueLengthLwm:
      let
        qItem = ctx.lhc.staged.ge(BlockNumber 0).expect "valid record"
        key = qItem.key
        nHeaders = qItem.data.revHdrs.len.uint
      ctx.headersUnprocMerge(key - nHeaders + 1, key)
      discard ctx.lhc.staged.delete key

  when verifyDataStructureOk:
    ctx.verifyStagedQueue(info, multiMode = false)

  when extraTraceMessages:
    trace info & ": reorg done", nStaged=ctx.lhc.staged.len


proc headersStagedTop*(ctx: FlareCtxRef): BlockNumber =
  ## Retrieve to staged block number
  let qItem = ctx.lhc.staged.le(high BlockNumber).valueOr:
    return BlockNumber(0)
  qItem.key

proc headersStagedChunks*(ctx: FlareCtxRef): int =
  ## Number of staged records
  ctx.lhc.staged.len

# ----------------

proc headersStagedInit*(ctx: FlareCtxRef) =
  ## Constructor
  ctx.lhc.staged = LinkedHChainQueue.init()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
