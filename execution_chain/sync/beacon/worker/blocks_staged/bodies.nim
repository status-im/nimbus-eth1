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
# Public functions
# ------------------------------------------------------------------------------

func bdyErrors*(buddy: BeaconBuddyRef): string =
  $buddy.only.nBdyRespErrors & "/" & $buddy.only.nBdyProcErrors

proc fetchRegisterError*(buddy: BeaconBuddyRef, slowPeer = false) =
  buddy.only.nBdyRespErrors.inc
  if fetchBodiesReqErrThresholdCount < buddy.only.nBdyRespErrors:
    if 1 < buddy.ctx.pool.nBuddies or not slowPeer:
      buddy.ctrl.zombie = true # abandon slow peer unless last one

proc bodiesFetch*(
    buddy: BeaconBuddyRef;
    request: BlockBodiesRequest;
    info: static[string];
      ): Future[Result[seq[BlockBody],void]]
      {.async: (raises: []).} =
  ## Fetch bodies from the network.
  let
    peer = buddy.peer
    start = Moment.now()
    nReq = request.blockHashes.len

  trace trEthSendSendingGetBlockBodies, peer, nReq, bdyErrors=buddy.bdyErrors

  var resp: Opt[BlockBodiesPacket]
  try:
    resp = await peer.getBlockBodies(request)
  except PeerDisconnected as e:
    buddy.only.nBdyRespErrors.inc
    buddy.ctrl.zombie = true
    `info` info & " error", peer, nReq, elapsed=(Moment.now() - start).toStr,
      error=($e.name), msg=e.msg, bdyErrors=buddy.bdyErrors
    return err()
  except CatchableError as e:
    buddy.fetchRegisterError()
    `info` info & " error", peer, nReq, elapsed=(Moment.now() - start).toStr,
      error=($e.name), msg=e.msg, bdyErrors=buddy.bdyErrors
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
    buddy.fetchRegisterError()
    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=0,
      elapsed=elapsed.toStr, ctrl=buddy.ctrl.state, bdyErrors=buddy.bdyErrors
    return err()

  let b: seq[BlockBody] = resp.get.bodies
  if b.len == 0 or nReq < b.len:
    buddy.fetchRegisterError()
    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
      elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      nRespErrors=buddy.only.nBdyRespErrors
    return err()

  # Ban an overly slow peer for a while when seen in a row. Also there is a
  # mimimum share of the number of requested headers expected, typically 10%.
  if fetchBodiesReqErrThresholdZombie < elapsed or
     b.len.uint64 * 100 < nReq.uint64 * fetchBodiesReqMinResponsePC:
    buddy.fetchRegisterError(slowPeer=true)
  else:
    buddy.only.nBdyRespErrors = 0 # reset error count

  trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
    elapsed=elapsed.toStr, ctrl=buddy.ctrl.state, bdyErrors=buddy.bdyErrors

  return ok(b)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

