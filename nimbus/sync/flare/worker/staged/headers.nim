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
  std/options,
  pkg/[chronicles, chronos, results],
  pkg/eth/p2p,
  pkg/stew/interval_set,
  "../../.."/[protocol, types],
  ../../worker_desc

logScope:
  topics = "flare headers"

const extraTraceMessages = false # or true
  ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc headersFetchReversed*(
    buddy: FlareBuddyRef;
    ivReq: BnRange;
    topHash: Hash256;
    info: static[string];
      ): Future[Result[seq[BlockHeader],void]]
      {.async.} =
  ## Get a list of headers in reverse order.
  let
    peer = buddy.peer
    useHash = (topHash != EMPTY_ROOT_HASH)
    req = block:
      if useHash:
        BlocksRequest(
          maxResults: ivReq.len.uint,
          skip:       0,
          reverse:    true,
          startBlock: HashOrNum(
            isHash:   true,
            hash:     topHash))
      else:
        BlocksRequest(
          maxResults: ivReq.len.uint,
          skip:       0,
          reverse:    true,
          startBlock: HashOrNum(
            isHash:   false,
            number:   ivReq.maxPt))

  when extraTraceMessages:
    trace trEthSendSendingGetBlockHeaders & " reverse", peer, ivReq,
      nReq=req.maxResults, useHash

  # Fetch headers from peer
  var resp: Option[blockHeadersObj]
  try:
    resp = await peer.getBlockHeaders(req)
  except TransportError as e:
    `info` info & ", stop", peer, ivReq, nReq=req.maxResults, useHash,
      error=($e.name), msg=e.msg
    return err()

  # Beware of peer terminating the session while fetching data
  if buddy.ctrl.stopped:
    return err()

  if resp.isNone:
    when extraTraceMessages:
      trace trEthRecvReceivedBlockHeaders, peer,
        ivReq, nReq=req.maxResults, respose="n/a", useHash
    return err()

  let h: seq[BlockHeader] = resp.get.headers
  if h.len == 0 or ivReq.len < h.len.uint:
    when extraTraceMessages:
      trace trEthRecvReceivedBlockHeaders, peer, ivReq, nReq=req.maxResults,
        useHash, nResp=h.len
    return err()

  when extraTraceMessages:
    trace trEthRecvReceivedBlockHeaders, peer, ivReq, nReq=req.maxResults,
      useHash, ivResp=BnRange.new(h[^1].number,h[0].number), nResp=h.len

  return ok(h)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
