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
# Private functions
# ------------------------------------------------------------------------------

# Copied from `nimbus_import`
func shortLog(a: chronos.Duration, parts = int.high): string =
  ## Returns string representation of Duration ``a`` as nanoseconds value.
  var
    res = ""
    v = a.nanoseconds()
    parts = parts

  template f(n: string, T: Duration) =
    if v >= T.nanoseconds():
      res.add($(uint64(v div T.nanoseconds())))
      res.add(n)
      v = v mod T.nanoseconds()
      dec parts
      if v == 0 or parts <= 0:
        return res

  f("s", Second)
  f("ms", Millisecond)
  f("us", Microsecond)
  f("ns", Nanosecond)

  res

# For some reason neither `formatIt` nor `$` works as expected with logging
# the `elapsed` variable, below. This might be due to the fact that the
# `headersFetchReversed()` function is a generic one, i.e. a template.
func toStr(a: chronos.Duration): string =
  a.shortLog(2)

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
  const
    threshold = fetchHeaderReqZombieThreshold # shortcut
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
    start = Moment.now()

  when extraTraceMessages:
    trace trEthSendSendingGetBlockHeaders & " reverse", peer, ivReq,
      nReq=req.maxResults, useHash

  # Fetch headers from peer
  var resp: Option[blockHeadersObj]
  try:
    # There is no obvious way to set an individual timeout for this call. The
    # eth/xx driver sets a global response timeout to `10s`. By how it is
    # implemented, the `Future` returned by `peer.getBlockHeaders(req)` cannot
    # reliably be used in a `withTimeout()` directive. It would rather crash
    # in `rplx` with a violated `req.timeoutAt <= Moment.now()` assertion.
    resp = await peer.getBlockHeaders(req)
  except TransportError as e:
    `info` info & " error", peer, ivReq, nReq=req.maxResults, useHash,
      elapsed=(Moment.now() - start).toStr, error=($e.name), msg=e.msg
    return err()

  # Kludge: Ban an overly slow peer for a while
  let elapsed = Moment.now() - start
  if threshold < elapsed:
    buddy.ctrl.zombie = true # abandon slow peer

  # Evaluate result
  if resp.isNone or buddy.ctrl.stopped:
    when extraTraceMessages:
      trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
        nResp=0, elapsed=elapsed.toStr, threshold, ctrl=buddy.ctrl.state
    return err()

  let h: seq[BlockHeader] = resp.get.headers
  if h.len == 0 or ivReq.len < h.len.uint:
    when extraTraceMessages:
      trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
        nResp=h.len, elapsed=elapsed.toStr, threshold, ctrl=buddy.ctrl.state
    return err()

  when extraTraceMessages:
    trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
      ivResp=BnRange.new(h[^1].number,h[0].number), nResp=h.len,
      elapsed=elapsed.toStr, threshold, ctrl=buddy.ctrl.state
  else:
    if buddy.ctrl.stopped:
      trace trEthRecvReceivedBlockHeaders, peer, nReq=req.maxResults, useHash,
        ivResp=BnRange.new(h[^1].number,h[0].number), nResp=h.len,
        elapsed=elapsed.toStr, threshold, ctrl=buddy.ctrl.state

  return ok(h)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
