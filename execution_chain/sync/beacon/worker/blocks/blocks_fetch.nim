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
  ./blocks_helpers

# ------------------------------------------------------------------------------
# Private helpers
# -----------------------------------------------------------------------------

proc getBlockBodies(
    buddy: BeaconBuddyRef;
    req: BlockBodiesRequest;
      ): Future[Result[FetchBodiesData,BeaconError]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockHeaders()`
  let start = Moment.now()
  var resp: BlockBodiesPacket

  try:
    resp = (await buddy.peer.getBlockBodies(req)).valueOr:
      return err((ENoException,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  # There is no obvious way to set an individual timeout for this call. The
  # eth/xx driver sets a global response timeout to `10s`. By how it is
  # implemented, the `Future` returned by `peer.getBlockBodies(req)` cannot
  # reliably be used in a `withTimeout()` directive. It would rather crash
  # in `rplx` with a violated `req.timeoutAt <= Moment.now()` assertion.
  return ok((move resp, Moment.now()-start))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchBodies*(
    buddy: BeaconBuddyRef;
    request: BlockBodiesRequest;
    info: static[string];
      ): Future[Result[seq[BlockBody],void]]
      {.async: (raises: []).} =
  ## Fetch bodies from the network.
  let
    peer = buddy.peer
    nReq = request.blockHashes.len

  trace trEthSendSendingGetBlockBodies,
    peer, nReq, bdyErrors=buddy.bdyErrors

  let rc = await buddy.getBlockBodies(request)
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
        buddy.only.nRespErrors.blk.inc
        buddy.ctrl.zombie = true
      of ECatchableError:
        buddy.bdyFetchRegisterError()

      info trEthRecvReceivedBlockBodies & " error", peer, nReq,
        elapsed=rc.error.elapsed.toStr, syncState=($buddy.syncState),
        error=rc.error.name, msg=rc.error.msg, bdyErrors=buddy.bdyErrors
      return err()

  # Evaluate result
  if rc.isErr or buddy.ctrl.stopped:
    buddy.bdyFetchRegisterError()
    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=0,
      elapsed=elapsed.toStr, syncState=($buddy.syncState),
      bdyErrors=buddy.bdyErrors
    return err()

  let b = rc.value.packet.bodies
  if b.len == 0 or nReq < b.len:
    buddy.bdyFetchRegisterError()
    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
      elapsed=elapsed.toStr, syncState=($buddy.syncState),
      nRespErrors=buddy.only.nRespErrors.blk
    return err()

  # Ban an overly slow peer for a while when seen in a row. Also there is a
  # mimimum share of the number of requested headers expected, typically 10%.
  if fetchBodiesErrTimeout < elapsed or
     b.len.uint64 * 100 < nReq.uint64 * fetchBodiesMinResponsePC:
    buddy.bdyFetchRegisterError(slowPeer=true)
  else:
    buddy.only.nRespErrors.blk = 0                  # reset error count
    buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)    # not last one or not error

  trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
    elapsed=elapsed.toStr, syncState=($buddy.syncState),
    bdyErrors=buddy.bdyErrors

  return ok(b)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------

