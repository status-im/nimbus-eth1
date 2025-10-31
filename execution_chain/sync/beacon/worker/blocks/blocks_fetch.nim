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

  if buddy.only.failedReq.state == SyncState.blocks and
     buddy.only.failedReq.blockHash == req.blockHashes[0]:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

  var resp: BlockBodiesPacket
  try:
    resp = (await buddy.peer.getBlockBodies(
      req, fetchBodiesRlpxTimeout)).valueOr:
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

template fetchBodies*(
    buddy: BeaconBuddyRef;
    request: BlockBodiesRequest;
    info: static[string];
      ): Opt[seq[BlockBody]] =
  ## Async/template
  ##
  ## Fetch bodies from the network.
  ##
  var bodyRc = Opt[seq[BlockBody]].err()
  block body:
    let
      peer {.inject,used.} = buddy.peer
      nReq {.inject,used.} = request.blockHashes.len

    trace trEthSendSendingGetBlockBodies,
      peer, nReq, nErrors=buddy.nErrors.fetch.bdy

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
          buddy.nErrors.fetch.bdy.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.bdyFetchRegisterError()
          discard buddy.only.thPutStats.hdr.bpsSample(elapsed, 0)
        of EAlreadyTriedAndFailed:
          # Just return `failed` (no error count or throughput stats)
          discard

        chronicles.info trEthRecvReceivedBlockBodies & " error", peer, nReq,
          ela=rc.error.elapsed.toStr, state=($buddy.syncState),
          error=rc.error.name, msg=rc.error.msg, nErrors=buddy.nErrors.fetch.bdy
        break body                                  # return err()

    # Evaluate result
    if rc.isErr or buddy.ctrl.stopped:
      buddy.bdyFetchRegisterError()
      trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=0,
        ela=elapsed.toStr, state=($buddy.syncState),
        nErrors=buddy.nErrors.fetch.bdy
      break body                                    # return err()

    # Verify the correct number of block bodies received
    let b = rc.value.packet.bodies
    if b.len == 0 or nReq < b.len:
      if nReq < b.len:
        # Bogus peer returning additional rubbish
        buddy.bdyFetchRegisterError(forceZombie=true)
      else:
        # No data available. For a fast enough rejection response, the
        # througput stats are degraded, only.
        discard buddy.only.thPutStats.blk.bpsSample(elapsed, 0)

        # Slow response, definitely not fast enough
        if fetchBodiesErrTimeout <= elapsed:
          buddy.bdyFetchRegisterError(slowPeer=true)

          # Do not repeat the same time-consuming failed request
          buddy.only.failedReq = BuddyFirstFetchReq(
            state:     SyncState.blocks,
            blockHash: request.blockHashes[0])

      trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
        ela=elapsed.toStr, state=($buddy.syncState),
        nErrors=buddy.nErrors.fetch.bdy
      break body                                    # return err()

    # Update download statistics
    let bps = buddy.only.thPutStats.blk.bpsSample(elapsed, b.getEncodedLength)

    # Request did not fail
    buddy.only.failedReq.reset

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchBodiesErrTimeout < elapsed:
      buddy.bdyFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.bdy = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one or not error

    trace trEthRecvReceivedBlockBodies, peer, nReq, nResp=b.len,
      ela=elapsed.toStr, thPut=(bps.toIECb(1) & "ps"),
      state=($buddy.syncState), nErrors=buddy.nErrors.fetch.bdy

    bodyRc = Opt[seq[BlockBody]].ok(b)

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
