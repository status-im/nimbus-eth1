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
  pkg/[chronicles, chronos, results],
  pkg/eth/[common, rlp],
  pkg/stew/interval_set,
  ../../../wire_protocol,
  ../worker_desc,
  ./headers_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getBlockHeaders(
    buddy: BeaconBuddyRef;
    req: BlockHeadersRequest;
      ): Future[Result[FetchHeadersData,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockHeaders()`
  let start = Moment.now()
  var resp: BlockHeadersPacket

  try:
    resp = (await buddy.peer.getBlockHeaders(
      req, fetchHeadersRlpxTimeout)).valueOr:
        return err((ENoException,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  # There is no obvious way to set an individual timeout for this call. The
  # eth/xx driver sets a global response timeout to `10s`. By how it is
  # implemented, the `Future` returned by `peer.getBlockHeaders(req)` cannot
  # reliably be used in a `withTimeout()` directive. It would rather crash
  # in `rplx` with a violated `req.timeoutAt <= Moment.now()` assertion.
  return ok((move resp, Moment.now()-start))

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template fetchHeadersReversed*(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    topHash: Hash32;
    info: static[string];
      ): Opt[seq[Header]] =
  ## Async/template
  ##
  ## From the ethXX argument peer implied by `buddy` fetch a list of headers
  ## in reversed order.
  ##
  var bodyRc = Opt[seq[Header]].err()
  block body:
    let
      peer {.inject,used.} = buddy.peer
      req = block:
        if topHash != emptyRoot:
          BlockHeadersRequest(
            maxResults: ivReq.len.uint,
            skip:       0,
            reverse:    true,
            startBlock: BlockHashOrNumber(
              isHash:   true,
              hash:     topHash))
        else:
          BlockHeadersRequest(
            maxResults: ivReq.len.uint,
            skip:       0,
            reverse:    true,
            startBlock: BlockHashOrNumber(
              isHash:   false,
              number:   ivReq.maxPt))

    trace trEthSendSendingGetBlockHeaders & " reverse", peer, req=ivReq,
      nReq=req.maxResults, hash=topHash.toStr, nErrors=buddy.nErrors.fetch.hdr

    let rc = await buddy.getBlockHeaders(req)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      block evalError:
        case rc.error.excp:
        of ENoException:
          break evalError
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.hdr.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.hdrFetchRegisterError()

        chronicles.info trEthRecvReceivedBlockHeaders & ": error", peer,
          req=ivReq, nReq=req.maxResults, hash=topHash.toStr,
          elapsed=rc.error.elapsed.toStr, state=($buddy.syncState),
          error=rc.error.name, msg=rc.error.msg,
          nErrors=buddy.nErrors.fetch.hdr
        break body                                 # return err()

    # Evaluate result
    if rc.isErr or buddy.ctrl.stopped:
      buddy.hdrFetchRegisterError()
      trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
        hash=topHash.toStr, nResp=0, elapsed=elapsed.toStr,
        state=($buddy.syncState), nErrors=buddy.nErrors.fetch.hdr
      break body                                   # return err()

    # Verify the correct number of block headers received
    let h = rc.value.packet.headers
    if h.len == 0 or ivReq.len < h.len.uint64:
      if ivReq.len < h.len.uint64:
        # Bogus peer returning additional rubbish
        buddy.hdrFetchRegisterError(forceZombie=true)
      else:
        # Data not avail but fast enough answer: degrade througput stats only
        discard buddy.only.thruPutStats.hdr.bpsSample(elapsed, 0)
        if fetchHeadersErrTimeout <= elapsed:
          # Slow rejection response
          buddy.hdrFetchRegisterError(slowPeer=true)
      trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
        hash=topHash.toStr, nResp=h.len, elapsed=elapsed.toStr,
        state=($buddy.syncState), nErrors=buddy.nErrors.fetch.hdr
      break body                                   # return err()

    # Verify that the first block number matches the request
    if h[^1].number != ivReq.minPt and ivReq.minPt != 0:
      buddy.hdrFetchRegisterError(forceZombie=true)
      trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
        hash=topHash.toStr, reqMinPt=ivReq.minPt.bnStr,
        respMinPt=h[^1].bnStr, nResp=h.len, elapsed=elapsed.toStr,
        state=($buddy.syncState), nErrors=buddy.nErrors.fetch.hdr
      break body

    # Update download statistics
    let bps = buddy.only.thruPutStats.hdr.bpsSample(elapsed, h.getEncodedLength)

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchHeadersErrTimeout < elapsed:
      buddy.hdrFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.hdr = 0                  # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash) # not last one or not error

    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
      hash=topHash.toStr, ivResp=BnRange.new(h[^1].number,h[0].number),
      nResp=h.len, elapsed=elapsed.toStr, throughput=(bps.toIECb(1) & "ps"),
      state=($buddy.syncState), nErrors=buddy.nErrors.fetch.hdr

    bodyRc = Opt[seq[Header]].ok(h)

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
