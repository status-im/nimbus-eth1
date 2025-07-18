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
  pkg/eth/common,
  pkg/stew/interval_set,
  ../../../wire_protocol,
  ../../worker_desc,
  ./headers_helpers

logScope:
  topics = "beacon sync"

# ------------------------------------------------------------------------------
# Public handler
# ------------------------------------------------------------------------------

proc getBlockHeadersCB*(
    buddy: BeaconBuddyRef;
    req: BlockHeadersRequest;
      ): Future[Result[FetchHeadersData,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockHeaders()`
  let start = Moment.now()
  var resp: BlockHeadersPacket

  try:
    resp = (await buddy.peer.getBlockHeaders(req)).valueOr:
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

proc fetchHeadersReversed*(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    topHash: Hash32;
    info: static[string];
      ): Future[Opt[seq[Header]]]
      {.async: (raises: []).} =
  ## From the ethXX argument peer implied by `buddy` fetch a list of headers
  ## in reversed order.
  let
    peer = buddy.peer
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

  trace trEthSendSendingGetBlockHeaders & " reverse", peer, ivReq,
    nReq=req.maxResults, hash=topHash.toStr, hdrErrors=buddy.hdrErrors

  let rc = await buddy.ctx.handler.getBlockHeaders(buddy, req)
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
        buddy.only.nRespErrors.hdr.inc
        buddy.ctrl.zombie = true
      of ECatchableError:
        buddy.hdrFetchRegisterError()

      info trEthRecvReceivedBlockHeaders & ": error", peer, ivReq,
        nReq=req.maxResults, hash=topHash.toStr, elapsed=rc.error.elapsed.toStr,
        syncState=($buddy.syncState), error=rc.error.name, msg=rc.error.msg,
        hdrErrors=buddy.hdrErrors
      return err()

  # Evaluate result
  if rc.isErr or buddy.ctrl.stopped:
    buddy.hdrFetchRegisterError()
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
      hash=topHash.toStr, nResp=0, elapsed=elapsed.toStr,
      syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors
    return err()

  let h = rc.value.packet.headers
  if h.len == 0 or ivReq.len < h.len.uint64:
    buddy.hdrFetchRegisterError()
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
      hash=topHash.toStr, nResp=h.len, elapsed=elapsed.toStr,
      syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors
    return err()

  # Verify that first block number matches
  if h[^1].number != ivReq.minPt:
    buddy.hdrFetchRegisterError()
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
      hash=topHash.toStr, ivReqMinPt=ivReq.minPt.bnStr, ivRespMinPt=h[^1].bnStr,
      nResp=h.len, elapsed=elapsed.toStr,
      syncState=($buddy.syncState), hdrErrors=buddy.hdrErrors
    return err()

  # Ban an overly slow peer for a while when seen in a row. Also there is a
  # mimimum share of the number of requested headers expected, typically 10%.
  if fetchHeadersErrTimeout < elapsed or
     h.len.uint64 * 100 < req.maxResults * fetchHeadersMinResponsePC:
    buddy.hdrFetchRegisterError(slowPeer=true)
  else:
    buddy.only.nRespErrors.hdr = 0                 # reset error count
    buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)   # not last one or not error

  trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
    hash=topHash.toStr, ivResp=BnRange.new(h[^1].number,h[0].number),
    nResp=h.len, elapsed=elapsed.toStr, syncState=($buddy.syncState),
    hdrErrors=buddy.hdrErrors

  return ok(h)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
