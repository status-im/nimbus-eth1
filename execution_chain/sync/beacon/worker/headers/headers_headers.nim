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
  ../update/update_eta,
  ../[helpers, worker_desc],
  ./[headers_fetch, headers_helpers, headers_unproc]

# ------------------------------------------------------------------------------
# Public helper functions
# ------------------------------------------------------------------------------

template headersFetch*(
    buddy: BeaconPeerRef;
    parent: Hash32;
    num: uint;
    info: static[string];
      ): Opt[seq[Header]] =
  ## Async/template
  ##
  ## From the p2p/ethXX network fetch as many headers as given as argument
  ## `num`. The returned list will be in reverse order, i.e. the first header
  ## is the most recent and the last one the most senior.
  ##
  let
    ctx = buddy.ctx
    peer {.inject,used.} = $buddy.peer              # logging only

  var bodyRc = Opt[seq[Header]].err()
  block body:
    # Make sure that this sync peer is not banned from header processing,
    # already
    if nStashHeadersErrThreshold < buddy.nErrors.apply.hdr:
      buddy.ctrl.zombie = true
      break body

    let
      # Fetch next available interval
      iv = ctx.headersUnprocFetch(num).valueOr:
        break body                                  # stop, exit function

      # Fetch headers for this range of block numbers
      rc = buddy.fetchHeadersReversed(iv, parent)

    # Job might have been cancelled or completed while downloading headers.
    # If so, no more bookkeeping of headers must take place. The *books*
    # might have been reset and prepared for the next stage.
    if ctx.hdrSessionStopped():
      break body                                    # stop, exit function

    if rc.isErr:
      ctx.headersUnprocCommit(iv, iv)               # clean up, revert `iv`
      break body                                    # stop, exit function

    # Boundary check for header block numbers
    let
      nHeaders = rc.value.len.uint64
      ivBottom = iv.maxPt - nHeaders + 1
    if rc.value[0].number != iv.maxPt or rc.value[^1].number != ivBottom:
      buddy.hdrProcRegisterError()
      ctx.headersUnprocCommit(iv, iv)               # clean up, revert `iv`
      debug info & ": Garbled header list", peer, iv, headers=rc.value.toStr,
        expected=(ivBottom,iv.maxPt).toStr, state=($buddy.syncState),
        nErrors=buddy.nErrors.fetch.hdr
      break body                                    # stop, exit function

    # Commit blocks received (and revert lower unused block numbers)
    ctx.headersUnprocCommit(iv, iv.minPt, iv.maxPt - nHeaders)
    bodyRc = rc

  bodyRc # return


proc headersStashOnDisk*(
  buddy: BeaconPeerRef;
  revHdrs: seq[Header];
  peerID: Hash;
  info: static[string];
    ): Opt[uint64] =
  ## Convenience wrapper, makes it easy to produce comparable messages
  ## whenever it is called, similar to `blocksImport()`. Unless complete
  ## failure, this function returns the number of headers stored.
  let
    ctx = buddy.ctx
    peer {.inject,used.} = $buddy.peer           # logging only
    dTop = ctx.hdrCache.antecedent.number        # current antecedent
    rc = ctx.hdrCache.put(revHdrs)               # verify and save headers

  if rc.isErr:
    # Mark peer that produced that unusable headers list as a zombie
    let srcPeer = buddy.getSyncPeer peerID
    if not srcPeer.isNil:
      srcPeer.only.nErrors.apply.hdr = nProcHeadersErrThreshold + 1

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
      warn "Header stash error (cancel this session)", iv=revHdrs.toStr,
        state=($buddy.syncState), nErrors=buddy.hdrErrors(),
        hdrFailCount=ctx.subState.procFailCount, error=rc.error
    else:
      debug info & ": Header stash error (skip remaining)", peer,
        iv=revHdrs.toStr, state=($buddy.syncState), nErrors=buddy.hdrErrors(),
        hdrFailCount=ctx.subState.procFailCount, error=rc.error

    return err()                                 # stop

  let dBottom = ctx.hdrCache.antecedent.number   # new antecedent
  trace info & ": Serialised headers stashed", peer,
    iv=(if dBottom < dTop: (dBottom,dTop-1).toStr else: "n/a"),
    nHeaders=(dTop - dBottom),
    nSkipped=(if rc.isErr: 0u64
              elif revHdrs[^1].number <= dBottom: (dBottom - revHdrs[^1].number)
              else: revHdrs.len.uint64),
    base=ctx.chain.baseNumber, head=ctx.chain.latestNumber,
    target=ctx.subState.headNum, targetHash=ctx.subState.headHash.short

  let srcPeer = buddy.getSyncPeer peerID
  if not srcPeer.isNil:
    srcPeer.only.nErrors.apply.hdr = 0           # reset error count

  ctx.updateEtaHeaders()                         # metrics update
  ok(dTop - dBottom)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
