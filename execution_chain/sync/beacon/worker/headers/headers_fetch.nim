# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  ../[helpers, worker_desc],
  ./headers_helpers

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc maybeSlowPeerError(
    buddy: BeaconPeerRef;
    elapsed: Duration;
    bn: BlockNumber;
      ): bool =
  ## Register slow response, definitely not fast enough
  if fetchHeadersErrTimeout <= elapsed:
    buddy.hdrFetchRegisterError(slowPeer=true)

    # Do not repeat the same time-consuming failed request
    buddy.only.failedReq = PeerFirstFetchReq(
      state:       SyncState.headers,
      blockNumber: bn)

    return true

  # false

func errStr(rc: Result[FetchHeadersData,BeaconError]): string =
  if rc.isErr:
    result = $rc.error.excp
    if 0 < rc.error.name.len:
      result &= "(" & rc.error.name & ")"
    if 0 < rc.error.msg.len:
      result &= "[" & rc.error.msg & "]"
  else:
    result = "n/a"

# ------------------------------------------------------------------------------
# Private function(s)
# ------------------------------------------------------------------------------

proc getBlockHeaders(
    buddy: BeaconPeerRef;
    req: BlockHeadersRequest;
    bn: BlockNumber;
      ): Future[Result[FetchHeadersData,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockHeaders()`
  let start = Moment.now()

  if buddy.only.failedReq.state == SyncState.headers and
     buddy.only.failedReq.blockNumber == bn:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

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
# Public function(s)
# ------------------------------------------------------------------------------

template fetchHeadersReversed*(
    buddy: BeaconPeerRef;
    ivReq: BnRange;
    topHash: Hash32;
      ): Opt[seq[Header]] =
  ## Async/template
  ##
  ## From the ethXX argument peer implied by `buddy` fetch a list of headers
  ## in reversed order.
  ##
  var bodyRc = Opt[seq[Header]].err()
  block body:
    const
      sendInfo = trEthSendSendingGetBlockHeaders
      recvInfo = trEthRecvReceivedBlockHeaders
    let
      peer {.inject,used.} = $buddy.peer           # logging only
      hash {.inject,used.} = topHash.toStr         # logging only
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

    trace sendInfo & " reverse", peer, req=($ivReq), nReq=req.maxResults, hash,
      state=($buddy.syncState), nErrors=buddy.nErrors.fetch.hdr

    let rc = await buddy.getBlockHeaders(req, BlockNumber ivReq.maxPt)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      block evalError:
        case rc.error.excp:
        of ENoException, ESyncerTermination:
          break evalError
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.hdr.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.hdrFetchRegisterError()
          buddy.hdrNoSampleSize(elapsed)
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, req=($ivReq), nReq=req.maxResults,
            hash, ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.hdr
          break body                               # return err()

        # Debug message for other errors
        debug recvInfo & " error", peer, req=($ivReq), nReq=req.maxResults,
          hash, ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.hdr
        break body                                 # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      state {.inject,used.} = $buddy.syncState      # logging only

    # Evaluate result
    if rc.isErr or buddy.ctrl.stopped:
      if not buddy.maybeSlowPeerError(elapsed, BlockNumber ivReq.maxPt):
        buddy.hdrFetchRegisterError()
      trace recvInfo & " error", peer, req=($ivReq), nReq=req.maxResults, hash,
        nResp=0, ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.hdr
      break body                                   # return err()

    # Verify the correct number of block headers received
    let h = rc.value.packet.headers
    if h.len == 0 or ivReq.len < h.len.uint64:
      if ivReq.len < h.len.uint64:
        # Bogus peer returning additional rubbish
        buddy.hdrFetchRegisterError(forceZombie=true)
      else:
        # No data available. For a fast enough rejection response, the
        # througput stats are degraded, only.
        buddy.hdrNoSampleSize(elapsed)

        # Slow response, definitely not fast enough
        discard buddy.maybeSlowPeerError(elapsed, BlockNumber ivReq.maxPt)

      trace recvInfo & " error", peer, nReq=req.maxResults, hash, nResp=h.len,
        ela, state, nErrors=buddy.nErrors.fetch.hdr
      break body                                   # return err()

    # Verify that the first block number matches the request
    if h[0].number != ivReq.maxPt and ivReq.maxPt != 0:
      buddy.hdrFetchRegisterError(forceZombie=true)
      trace recvInfo & " error", peer, nReq=req.maxResults, hash,
        reqMaxPt=ivReq.maxPt, respMaxPt=h[0].number, nResp=h.len,
        ela, state, nErrors=buddy.nErrors.fetch.hdr
      break body

    # Update download statistics
    let bps = buddy.hdrSampleSize(elapsed, h.getEncodedLength)

    # Request did not fail
    buddy.only.failedReq.reset

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchHeadersErrTimeout < elapsed:
      buddy.hdrFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.hdr = 0                  # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash) # not last one or not error

    trace recvInfo, peer, nReq=req.maxResults, hash, ivResp=(h[^1].number,
      h[0].number).toStr, nResp=h.len, ela, thPut=(bps.toIECb(1) & "ps"),
      state, nErrors=buddy.nErrors.fetch.hdr

    bodyRc = Opt[seq[Header]].ok(h)

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
