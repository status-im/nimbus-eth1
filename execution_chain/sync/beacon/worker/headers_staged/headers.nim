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
  ../../worker_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc registerError(buddy: BeaconBuddyRef, slowPeer = false) =
  buddy.incHdrRespErrors()
  if fetchHeadersReqErrThresholdCount < buddy.nHdrRespErrors:
    if 1 < buddy.ctx.pool.nBuddies or not slowPeer:
      buddy.ctrl.zombie = true # abandon slow peer unless last one

# ------------------------------------------------------------------------------
# Public debugging & logging helpers
# ------------------------------------------------------------------------------

func hdrErrors*(buddy: BeaconBuddyRef): string =
  $buddy.nHdrRespErrors & "/" & $buddy.nHdrProcErrors()

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
    start = Moment.now()

  trace trEthSendSendingGetBlockHeaders & " reverse", peer, ivReq,
    nReq=req.maxResults, hash=topHash.toStr, hdrErrors=buddy.hdrErrors

  # Fetch headers from peer
  var resp: Opt[BlockHeadersPacket]
  try:
    # There is no obvious way to set an individual timeout for this call. The
    # eth/xx driver sets a global response timeout to `10s`. By how it is
    # implemented, the `Future` returned by `peer.getBlockHeaders(req)` cannot
    # reliably be used in a `withTimeout()` directive. It would rather crash
    # in `rplx` with a violated `req.timeoutAt <= Moment.now()` assertion.
    resp = await peer.getBlockHeaders(req)
  except CatchableError as e:
    buddy.registerError()
    `info` info & " error", peer, ivReq, nReq=req.maxResults,
      hash=topHash.toStr, elapsed=(Moment.now() - start).toStr,
      error=($e.name), msg=e.msg, hdrErrors=buddy.hdrErrors
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
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
      hash=topHash.toStr, nResp=0, elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      hdrErrors=buddy.hdrErrors
    return err()

  let h: seq[Header] = resp.get.headers
  if h.len == 0 or ivReq.len < h.len.uint64:
    buddy.registerError()
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
      hash=topHash.toStr, nResp=h.len, elapsed=elapsed.toStr,
      ctrl=buddy.ctrl.state, hdrErrors=buddy.hdrErrors
    return err()

  # Ban an overly slow peer for a while when seen in a row. Also there is a
  # mimimum share of the number of requested headers expected, typically 10%.
  if fetchHeadersReqErrThresholdZombie < elapsed or
     h.len.uint64 * 100 < req.maxResults * fetchHeadersReqMinResponsePC:
    buddy.registerError()
  else:
    buddy.nHdrRespErrors = 0 # reset error count

  trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults,
    hash=topHash.toStr, ivResp=BnRange.new(h[^1].number,h[0].number),
    nResp=h.len, elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
    hdrErrors=buddy.hdrErrors

  return ok(h)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
