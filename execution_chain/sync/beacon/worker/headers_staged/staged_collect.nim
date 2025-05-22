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
  ../../worker_desc,
  ./[headers_fetch, staged_headers]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc fetchRev(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    parent: Hash32;
    info: static[string];
      ): Future[Result[seq[Header],void]]
      {.async: (raises: []).} =
  ## Helper/wrapper
  var rev = (await buddy.headersFetchReversed(ivReq, parent, info)).valueOr:
    buddy.headersUpdateBuddyErrorState()
    debug info & ": header fetch error", peer=buddy.peer, ivReq,
      nReq=ivReq.len, parent=parent.toStr, syncState=($buddy.syncState),
      hdrErrors=buddy.hdrErrors
    return err()
  ok(rev)


proc subRangeMinEndingAt(iv: BnRange; maxPt: BlockNumber): BlockNumber =
  ## Get the left end of reasonably sized sub-interval of argument `iv`
  ## ending at argument `maxPt`.
  if maxPt + 1 <= iv.minPt + nFetchHeadersRequest:
    iv.minPt
  else:
    maxPt - nFetchHeadersRequest + 1

# ------------------------------------------------------------------------------
# Public logging helpers
# ------------------------------------------------------------------------------

func bnStr*(w: LinkedHChain | ref LinkedHChain): string =
  w.revHdrs.bnStr

# ------------------------------------------------------------------------------
# Public helper functions
# ------------------------------------------------------------------------------

func collectModeStopped*(ctx: BeaconCtxRef): bool =
  ## Helper, checks whether there is a general stop conditions based on
  ## state settings (not on sync peer ctrl as `buddy.ctrl.running`.)
  ctx.poolMode or
  ctx.pool.lastState != headers or
  ctx.hdrCache.state != collecting


proc collectAndStashOnDiskCache*(
    buddy: BeaconBuddyRef;
    iv: BnRange;
    topLink: Hash32;
    info: static[string];
      ): Future[BlockNumber] {.async: (raises: []).} =
  ## Fetch header interval deterministically by hash and store it directly
  ## on the header chain cache.
  ##
  ## The function returns the largest block number not fetched/stored.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer
  var
    ivTop = iv.maxPt                   # top end of the current range to fetch
    parent = topLink                   # parent hash for the next fetch request

  block fetchHeadersBody:

    while ctx.hdrCache.state == collecting:
      let
        # Figure out base point for top-most sub-range of argument `iv`
        ivReqMin = iv.subRangeMinEndingAt ivTop

        # Request interval
        ivReq = BnRange.new(ivReqMin, ivTop)

        # Fetch headers for this range of block numbers
        rev = (await buddy.fetchRev(ivReq, parent, info)).valueOr:
          break fetchHeadersBody       # error => exit block

      # Job might have been cancelled while downloading headrs
      if ctx.collectModeStopped():
        break fetchHeadersBody         # stop => exit block

      # Store it on the header chain cache
      if not buddy.headersStashOnDisk(rev, info):
        break fetchHeadersBody         # error => exit block

      # Note that `put()` might not have used all of the `rev[]` items for
      # updating the antecedent (aka `ctx.dangling`.) So `rev[^1]` might be
      # an ancestor of the antecedent.
      #
      # By design, the unused items from `rev[]` list may savely be considered
      # as consumed so that the next cycle can continue. In practice, if there
      # are used `rev[]` items then the `state` will have changed which is
      # handled in the `while` loop header clause.
      #
      # Other possibilities would imply that `put()` was called from several
      # instances with oberlapping `rev[]` argument lists which is included
      # by the administration of the `iv` argument for this function
      # `collectAndStashOnDiskCache()`.

      # Update remaining range to fetch and check for end-of-loop condition
      let newTopBefore = ivTop - BlockNumber(rev.len)
      if newTopBefore < iv.minPt:
        break                          # exit while() loop

      ivTop = newTopBefore             # mostly results in `ivReq.minPt-1`
      parent = rev[^1].parentHash      # parent hash for next fetch request
      # End loop

    trace info & ": fetched and stored headers", peer, iv, nHeaders=iv.len,
      D=ctx.dangling.bnStr, syncState=($buddy.syncState),
      hdrErrors=buddy.hdrErrors

    # Reset header process errors (not too many consecutive failures this time)
    buddy.nHdrProcErrors = 0           # all OK, reset error count
    return iv.minPt-1

  # Start processing some error or an incomplete fetch/store result

  trace info & ": partially fetched/stored headers", peer,
    iv=(if ivTop < iv.maxPt: BnRange.new(ivTop+1,iv.maxPt).bnStr else: "n/a"),
    nHeaders=(iv.maxPt-ivTop), D=ctx.dangling.bnStr,
    syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors

  return ivTop                         # there is some left over range


proc collectAndStageOnMemQueue*(
    buddy: BeaconBuddyRef;
    iv: BnRange;
    lhc: ref LinkedHChain;
    info: static[string];
      ): Future[BlockNumber] {.async: (raises: []).} =
  ## Fetch header interval opportunistically by hash and append it on the
  ## `lhc` argument.
  ##
  ## The function returns the largest block number not fetched/stored.
  ##
  let
    ctx = buddy.ctx
    peer = buddy.peer
  var
    ivTop = iv.maxPt                   # top end of the current range to fetch
    parent = EMPTY_ROOT_HASH           # parent hash for next fetch request

  block fetchHeadersBody:

    while true:
      let
        # Figure out base point for top-most sub-range of argument `iv`
        ivReqMin = iv.subRangeMinEndingAt ivTop

        # Request interval
        ivReq = BnRange.new(ivReqMin, ivTop)

        # Fetch headers for this range of block numbers
        rev = (await buddy.fetchRev(ivReq, parent, info)).valueOr:
          break fetchHeadersBody       # error => exit block

      # Job might have been cancelled while downloading headrs
      if ctx.collectModeStopped():
        break fetchHeadersBody         # stop => exit block

      # While assembling a `LinkedHChainRef`, only boundary checks are used to
      # verify that the header lists are acceptable. A thorough check will be
      # performed later when storing this list on the header chain cache.

      # Boundary check for block numbers
      let ivBottom = ivTop - rev.len.uint64 + 1
      if rev[0].number != ivTop or rev[^1].number != ivBottom:
        buddy.headersUpdateBuddyProcError()
        debug info & ": header queue error", peer, iv, ivReq,
          receivedHeaders=rev.bnStr, expected=(ivBottom,ivTop).bnStr,
          syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors
        break fetchHeadersBody         # error => exit block

      # Check/update hashes
      let hash0 = rev[0].computeBlockHash
      if lhc.revHdrs.len == 0:
        lhc.hash = hash0
      else:
        if lhc.revHdrs[^1].parentHash != hash0:
          buddy.headersUpdateBuddyProcError()
          debug info & ": header queue error", peer, iv, ivReq,
            hash=hash0.toStr, expected=lhc.revHdrs[^1].parentHash.toStr,
            syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors
          break fetchHeadersBody       # error => exit block

      lhc.revHdrs &= rev

      # Update remaining range to fetch and check for end-of-loop condition
      if ivTop < iv.minPt + rev.len.uint64:
        break                          # exit while loop

      parent = rev[^1].parentHash      # continue deterministically
      ivTop -= rev.len.uint64          # mostly results in `ivReq.minPt-1`
      # End loop

    trace info & ": fetched and staged all headers", peer, iv,
      D=ctx.dangling.bnStr, nHeaders=iv.len, syncState=($buddy.syncState),
      hdrErrors=buddy.hdrErrors

    # Reset header process errors (not too many consecutive failures this time)
    buddy.nHdrProcErrors = 0           # all OK, reset error count

    return iv.minPt-1                  # all fetched as instructed
    # End block: `fetchHeadersBody`

  # Start processing some error or an incomplete fetch/stage result

  trace info & ": partially fetched and staged headers", peer, iv,
    D=ctx.dangling.bnStr, stagedHeaders=lhc.bnStr, nHeaders=lhc.revHdrs.len,
    syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors

  return ivTop                         # there is some left over range

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
