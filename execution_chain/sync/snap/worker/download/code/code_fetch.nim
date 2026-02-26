# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos, minilru, stew/interval_set],
  ../../../../wire_protocol,
  ../../[helpers, state_db, worker_desc],
  ./code_helpers

type
  FetchCodesResult* = Result[ByteCodesPacket,ErrorType]
    ## Shortcut

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc registerPeerError(buddy: SnapPeerRef; root: StateRoot; slowPeer=false) =
  ## Do not repeat the same time-consuming failed request for the same state
  ## root.
  buddy.cdeFetchRegisterError(slowPeer)
  buddy.only.failedReq.stateRoot.put(root,0u8)

proc maybeSlowPeerError(buddy: SnapPeerRef; ela: Duration; root: StateRoot) =
  ## Register slow response, definitely not fast enough
  if fetchCodesSnapTimeout <= ela:
    buddy.registerPeerError(root, slowPeer=true)
  else:
    buddy.cdeFetchRegisterError()


proc getCodes(
    buddy: SnapPeerRef;
    stateRoot: StateRoot;                           # DB state (error handling)
    req: ByteCodesRequest;                          # fetch request
      ): Future[Result[FetchCodesData,SnapError]]
      {.async: (raises: []).} =
  ## Wrapper around `getByteCodes()`
  let start = Moment.now()

  buddy.only.failedReq.stateRoot.peek(stateRoot).isErrOr:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

  var resp: ByteCodesPacket
  try:
    resp = (await buddy.peer.getByteCodes(
                    req, fetchCodesSnapTimeout)).valueOr:
        return err((EGeneric,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  return ok((move resp, Moment.now()-start))


func errStr(rc: Result[FetchCodesData,SnapError]): string =
  if rc.isErr:
    result = $rc.error.excp
    if 0 < rc.error.name.len:
      result &= "(" & rc.error.name & ")"
    if 0 < rc.error.msg.len:
      result &= "[" & rc.error.msg & "]"
  else:
    result = "n/a"

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template fetchCodes*(
    buddy: SnapPeerRef;
    stateRoot: StateRoot;                           # DB state (error handling)
    codesReq: seq[CodeHash];                        # List of code keys
      ): FetchCodesResult =
  ## Async/template
  ##
  ## Fetch byte codes from the network.
  ##
  var bodyRc = FetchCodesResult.err(EGeneric)
  block body:
    const
      sendInfo = trSnapSendSendingGetByteCodes
      recvInfo = trSnapRecvReceivedByteCodes
    let
      nReqCodes {.inject.} = codesReq.len
      fetchReq = ByteCodesRequest(
        hashes: codesReq.to(seq[Hash32]),
        bytes:  fetchCodesSnapBytesLimit)
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only

    trace sendInfo, peer, root, nReqCodes,
      state=($buddy.syncState), nErrors=buddy.nErrors.fetch.cde

    let rc = await buddy.getCodes(stateRoot, fetchReq)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      bodyRc = FetchCodesResult.err(rc.error.excp)
      block evalError:
        case rc.error.excp:
        of EGeneric:
          break evalError
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, root, nReqCodes,
            ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.cde
          break body                                # return err()
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.cde.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.cdeFetchRegisterError()
        of ENoDataAvailable, EMissingEthContext:
          # Not allowed here -- internal error
          raiseAssert "Unexpected error " & $rc.error.excp

        # Debug message for other errors
        debug recvInfo & " error", peer, root, nReqCodes,
          ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.cde
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      state {.inject,used.} = $buddy.syncState      # logging only

    # Evaluate error result (if any)
    if rc.isErr or buddy.ctrl.stopped:
      buddy.maybeSlowPeerError(elapsed, stateRoot)
      trace recvInfo & " error", peer, root, nReqCodes,
        ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.cde
      break body                                    # return err()

    # Check against obvious protocol violations
    let nRespCodes {.inject.} = rc.value.packet.codes.len

    if nRespCodes == 0:
      # Both, proof + slots are empty. This means that there is no byte
      # codes data available for this state root.
      buddy.registerPeerError(stateRoot)
      trace recvInfo & " not available", peer, root, nReqCodes, nRespCodes,
        ela, state, nErrors=buddy.nErrors.fetch.cde
      bodyRc = FetchCodesResult.err(ENoDataAvailable)
      break body                                  # return err()

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchCodesSnapTimeout < elapsed:
      buddy.cdeFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.cde = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one/error

    trace recvInfo, peer, root, nReqCodes, nRespCodes,
      ela, state, nErrors=buddy.nErrors.fetch.cde

    bodyRc = FetchCodesResult.ok(rc.value.packet)

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
