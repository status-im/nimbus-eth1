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
  ../../worker_desc,
  ./[headers_fetch, headers_helpers, headers_unproc]

import
  ./headers_debug

# ------------------------------------------------------------------------------
# Public helper functions
# ------------------------------------------------------------------------------

proc headersFetch*(
    buddy: BeaconBuddyRef;
    parent: Hash32;
    num: uint;
    info: static[string];
      ): Future[Opt[seq[Header]]]
      {.async: (raises: []).} =
  ## From the p2p/ethXX network fetch as many headers as given as argument
  ## `num`. The returned list will be in reverse order, i.e. the first header
  ## is the most recent and the last one the most senior.
  let
    ctx = buddy.ctx
    peer = buddy.peer

  # Make sure that this sync peer is not banned from header processing,
  # already
  if nStashHeadersErrThreshold < buddy.nHdrProcErrors():
    buddy.ctrl.zombie = true
    return Opt.none(seq[Header])

  let
    # Fetch next available interval
    iv = ctx.headersUnprocFetch(num).valueOr:
      return Opt.none(seq[Header])                  # stop, exit function

    # Fetch headers for this range of block numbers
    rc = await buddy.fetchHeadersReversed(iv, parent, info)

  # Job might have been cancelled or completed while downloading headers.
  # If so, no more bookkeeping of headers must take place. The *books*
  # might have been reset and prepared for the next stage.
  if ctx.hdrSessionStopped():
    return Opt.none(seq[Header])                    # stop, exit function

  if rc.isErr:
    ctx.headersUnprocCommit(iv, iv)                 # clean up, revert `iv`
    return Opt.none(seq[Header])                    # stop, exit function

  # Boundary check for header block numbers
  let
    nHeaders = rc.value.len.uint64
    ivBottom = iv.maxPt - nHeaders + 1
  if rc.value[0].number != iv.maxPt or rc.value[^1].number != ivBottom:
    buddy.hdrProcRegisterError()
    ctx.headersUnprocCommit(iv, iv)                 # clean up, revert `iv`
    debug info & ": Garbled header list", peer, iv, headers=rc.value.bnStr,
      expected=(ivBottom,iv.maxPt).bnStr, syncState=($buddy.syncState),
      hdrErrors=buddy.hdrErrors
    return Opt.none(seq[Header])                    # stop, exit function

  # Commit blocks received (and revert lower unused block numbers)
  ctx.headersUnprocCommit(iv, iv.minPt, iv.maxPt - nHeaders)
  return rc


proc headersStashOnDisk*(
  buddy: BeaconBuddyRef;
  revHdrs: seq[Header];
  peerID: Hash;
  info: static[string];
    ): bool =
  ## Convenience wrapper, makes it easy to produce comparable messages
  ## whenever it is called similar to `blocksImport()`.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    dTop = ctx.hdrCache.antecedent.number        # current antecedent
    rc = ctx.hdrCache.put(revHdrs)               # verify and save headers

  if rc.isErr:
    # Mark peer that produced that unusable headers list as a zombie
    ctx.setHdrProcFail peerID

    # Check whether it is enough to skip the current headers list, only
    if ctx.subState.procFailNum != dTop:
      ctx.subState.procFailNum = dTop            # OK, this is a new block
      ctx.subState.procFailCount = 1

    else:
      ctx.subState.procFailCount.inc             # block num was seen, already

      # Cancel the whole download if needed
      if nStashHeadersErrThreshold < ctx.subState.procFailCount:
        ctx.subState.cancelRequest = true        # So require queue reset

    # Proper logging ..
    if ctx.subState.cancelRequest:
      warn "Header stash error (cancel this session)", iv=revHdrs.bnStr,
        syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors,
        hdrFailCount=ctx.subState.procFailCount, error=rc.error
    else:
      info "Header stash error (skip remaining)", iv=revHdrs.bnStr,
        syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors,
        hdrFailCount=ctx.subState.procFailCount, error=rc.error

    return false                                 # stop

  let dBottom = ctx.hdrCache.antecedent.number   # new antecedent
  trace info & ": Serialised headers stashed", peer,
    iv=(if dBottom < dTop: (dBottom,dTop-1).bnStr else: "n/a"),
    nHeaders=(dTop - dBottom),
    nSkipped=(if rc.isErr: 0u64
              elif revHdrs[^1].number <= dBottom: (dBottom - revHdrs[^1].number)
              else: revHdrs.len.uint64),
    base=ctx.chain.baseNumber.bnStr, head=ctx.chain.latestNumber.bnStr,
    target=ctx.subState.head.bnStr, targetHash=ctx.subState.headHash.short,
    hdr=ctx.hdr.bnStr

  ctx.resetHdrProcErrors peerID                  # reset error count
  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
