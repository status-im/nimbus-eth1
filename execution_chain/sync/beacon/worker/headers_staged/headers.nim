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
  std/options,
  pkg/[chronicles, chronos, results],
  pkg/eth/common,
  pkg/stew/interval_set,
  ../../../protocol,
  ../../../protocol/eth/eth_types,
  ../../worker_desc,
  ../../../../networking/p2p

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc registerError(buddy: BeaconBuddyRef) =
  buddy.only.nHdrRespErrors.inc
  if fetchHeadersReqErrThresholdCount < buddy.only.nHdrRespErrors:
    buddy.ctrl.zombie = true # abandon slow peer

# ------------------------------------------------------------------------------
# Public debugging & logging helpers
# ------------------------------------------------------------------------------

func hdrErrors*(buddy: BeaconBuddyRef): string =
  $buddy.only.nHdrRespErrors & "/" & $buddy.only.nHdrProcErrors


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headersFetchReversed*(
    buddy: BeaconBuddyRef;
    ivReq: BnRange;
    topHash: Hash32;
    info: static[string];
      ): Future[Result[seq[Header],void]]
      {.async: (raises: []).} =
  ## Get a list of headers in reverse order.
  let
    peer = buddy.peer
    useHash = (topHash != emptyRoot)
    req = block:
      if useHash:
        EthBlocksRequest(
          maxResults: ivReq.len.uint,
          skip:       0,
          reverse:    true,
          startBlock: BlockHashOrNumber(
            isHash:   true,
            hash:     topHash))
      else:
        EthBlocksRequest(
          maxResults: ivReq.len.uint,
          skip:       0,
          reverse:    true,
          startBlock: BlockHashOrNumber(
            isHash:   false,
            number:   ivReq.maxPt))
    start = Moment.now()

  trace trEthSendSendingGetBlockHeaders & " reverse", peer, ivReq,
    nReq=req.maxResults, useHash, hdrErrors=buddy.hdrErrors

  # Fetch headers from peer
  var resp: Option[blockHeadersObj]
  try:
    # There is no obvious way to set an individual timeout for this call. The
    # eth/xx driver sets a global response timeout to `10s`. By how it is
    # implemented, the `Future` returned by `peer.getBlockHeaders(req)` cannot
    # reliably be used in a `withTimeout()` directive. It would rather crash
    # in `rplx` with a violated `req.timeoutAt <= Moment.now()` assertion.
    resp = await peer.getBlockHeaders(req)
  except CatchableError as e:
    buddy.registerError()
    `info` info & " error", peer, ivReq, nReq=req.maxResults, useHash,
      elapsed=(Moment.now() - start).toStr, error=($e.name), msg=e.msg,
      hdrErrors=buddy.hdrErrors
    return err()

  # This round trip time `elapsed` is the real time, not necessarily the
  # time relevant for network timeout which would throw an exception when
  # the maximum response time has exceeded (typically set to 10s.)
  #
  # If the real round trip time `elapsed` is to long, the error score is
  # inceased. Not until the error score will pass a certian threshold (for
  # being too slow in consecutive conversations), the peer will be abandoned.
  let elapsed = Moment.now() - start

  # Evaluate result
  if resp.isNone or buddy.ctrl.stopped:
    buddy.registerError()
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
      nResp=0, elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      hdrErrors=buddy.hdrErrors
    return err()

  let h: seq[Header] = resp.get.headers
  if h.len == 0 or ivReq.len < h.len.uint64:
    buddy.registerError()
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
      nResp=h.len, elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      hdrErrors=buddy.hdrErrors
    return err()

  # Ban an overly slow peer for a while when seen in a row. Also there is a
  # mimimum share of the number of requested headers expected, typically 10%.
  if fetchHeadersReqErrThresholdZombie < elapsed or
     h.len.uint64 * 100 < req.maxResults * fetchHeadersReqMinResponsePC:
    buddy.registerError()
  else:
    buddy.only.nHdrRespErrors = 0 # reset error count

  trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
    ivResp=BnRange.new(h[^1].number,h[0].number), nResp=h.len,
    elapsed=elapsed.toStr, ctrl=buddy.ctrl.state, hdrErrors=buddy.hdrErrors

  return ok(h)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
