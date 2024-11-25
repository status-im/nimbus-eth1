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
  pkg/eth/[common, p2p],
  pkg/stew/interval_set,
  ../../../protocol,
  ../../worker_desc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchRegisterError*(buddy: BeaconBuddyRef) =
  buddy.only.nBdyRespErrors.inc
  if fetchBodiesReqThresholdCount < buddy.only.nBdyRespErrors:
    buddy.ctrl.zombie = true # abandon slow peer

proc bodiesFetch*(
    buddy: BeaconBuddyRef;
    blockHashes: seq[Hash32];
    info: static[string];
      ): Future[Result[seq[BlockBody],void]]
      {.async: (raises: []).} =
  ## Fetch bodies from the network.
  let
    peer = buddy.peer
    start = Moment.now()
    nReq = blockHashes.len

  trace trEthSendSendingGetBlockBodies, peer, nReq,
    nRespErrors=buddy.only.nBdyRespErrors

  var resp: Option[blockBodiesObj]
  try:
    resp = await peer.getBlockBodies(blockHashes)
  except CatchableError as e:
    buddy.fetchRegisterError()
    `info` info & " error", peer, nReq, elapsed=(Moment.now() - start).toStr,
      error=($e.name), msg=e.msg, nRespErrors=buddy.only.nBdyRespErrors
    return err()

  let elapsed = Moment.now() - start

  # Evaluate result
  if resp.isNone or buddy.ctrl.stopped:
    buddy.fetchRegisterError()
    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=0,
      elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      nRespErrors=buddy.only.nBdyRespErrors
    return err()

  let b: seq[BlockBody] = resp.get.blocks
  if b.len == 0 or nReq < b.len:
    buddy.fetchRegisterError()
    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
      elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      nRespErrors=buddy.only.nBdyRespErrors
    return err()

  # Ban an overly slow peer for a while when seen in a row. Also there is a
  # mimimum share of the number of requested headers expected, typically 10%.
  if fetchBodiesReqThresholdZombie < elapsed or
     b.len.uint64 * 100 < nReq.uint64 * fetchBodiesReqMinResponsePC:
    buddy.fetchRegisterError()
  else:
    buddy.only.nBdyRespErrors = 0 # reset error count

  trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
    elapsed=elapsed.toStr, ctrl=buddy.ctrl.state,
      nRespErrors=buddy.only.nBdyRespErrors

  return ok(b)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

