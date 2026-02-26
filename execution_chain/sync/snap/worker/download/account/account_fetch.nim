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
  pkg/[chronicles, chronos, minilru],
  ../../../../wire_protocol,
  ../../[helpers, state_db, worker_desc],
  ./account_helpers

type
  FetchAccountsResult* = Result[AccountRangePacket,ErrorType]
    ## Shortcut

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc registerPeerError(buddy: SnapPeerRef; root: StateRoot; slowPeer=false) =
  ## Do not repeat the same time-consuming failed request
  buddy.accFetchRegisterError(slowPeer)
  buddy.only.failedReq.stateRoot.put(root,0u8)

proc maybeSlowPeerError(buddy: SnapPeerRef; ela: Duration; root: StateRoot) =
  ## Register slow response, definitely not fast enough
  if fetchAccountSnapTimeout <= ela:
    buddy.registerPeerError(root, slowPeer=true)
  else:
    buddy.accFetchRegisterError()


proc getAccounts(
    buddy: SnapPeerRef;
    req: AccountRangeRequest;
      ): Future[Result[FetchAccountsData,SnapError]]
      {.async: (raises: []).} =
  ## Wrapper around `getAccountRange()`
  let start = Moment.now()

  buddy.only.failedReq.stateRoot.peek(StateRoot(req.rootHash)).isErrOr:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

  var resp: AccountRangePacket
  try:
    resp = (await buddy.peer.getAccountRange(
                    req, fetchAccountSnapTimeout)).valueOr:
        return err((EGeneric,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  return ok((move resp, Moment.now()-start))


func errStr(rc: Result[FetchAccountsData,SnapError]): string =
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

template fetchAccounts*(
    buddy: SnapPeerRef;
    stateRoot: StateRoot;                           # DB state
    ivReq: ItemKeyRange;                            # Range to be fetched
      ): FetchAccountsResult =
  ## Async/template
  ##
  ## Fetch accounts from the network.
  ##
  var bodyRc = FetchAccountsResult.err(EGeneric)
  block body:
    const
      sendInfo = trSnapSendSendingGetAccountRange
      recvInfo = trSnapRecvReceivedAccountRange
    let
      fetchReq = AccountRangeRequest(
        rootHash:      stateRoot.Hash32,
        startingHash:  ivReq.minPt.to(Hash32),
        limitHash:     ivReq.maxPt.to(Hash32),
        responseBytes: fetchAccountSnapBytesLimit)
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only
      reqAcc {.inject,used.} = ivReq.flStr          # logging only
      nReqAcc {.inject,used.} = ivReq.len.flStr     # logging only

    trace sendInfo, peer, root, reqAcc, nReqAcc,
      state=($buddy.syncState), nErrors=buddy.nErrors.fetch.acc

    let rc = await buddy.getAccounts(fetchReq)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      bodyRc = FetchAccountsResult.err(rc.error.excp)
      block evalError:
        case rc.error.excp:
        of EGeneric:
          break evalError
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, root, reqAcc, nReqAcc,
            ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.acc
          break body                                # return err()
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.acc.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.accFetchRegisterError()
        of ENoDataAvailable, EMissingEthContext:
          # Not allowed here -- internal error
          raiseAssert "Unexpected error " & $rc.error.excp

        # Debug message for other errors
        debug recvInfo & " error", peer, root, reqAcc, nReqAcc,
          ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.acc
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      state {.inject,used.} = $buddy.syncState      # logging only

    # Evaluate error result (if any)
    if rc.isErr or buddy.ctrl.stopped:
      buddy.maybeSlowPeerError(elapsed, stateRoot)
      trace recvInfo & " error", peer, root, reqAcc, nReqAcc,
        ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.acc
      break body                                    # return err()

    # Check against obvious protocol violations
    let
      nRespAcc {.inject.} = rc.value.packet.accounts.len
      nRespProof {.inject.} = rc.value.packet.proof.len
    var
      respAcc {.inject,used.} = "n/a"               # logging only

    if 0 < nRespAcc:
      let
        accMin = rc.value.packet.accounts[0].accHash.to(ItemKey)
        accMax = rc.value.packet.accounts[^1].accHash.to(ItemKey)

      respAcc = (accMin,accMax).flStr               # logging only

      if accMin < ivReq.minPt:
        trace recvInfo & " min account too low", peer, root, reqAcc, nReqAcc,
          respAcc, nRespAcc, nRespProof, ela, state,
          nErrors=buddy.nErrors.fetch.acc
        break body                                  # return err()

      # According to specs, the peer must respond with at least one account
      # value. If there is no account in the `ivReq` range, then the next
      # account beyond `ivReq` is to be returned. This leads to implementations
      # like `Geth` to always return the next account beyond the requested
      # `ivReq` range, regardless of the number of accounts within.
      if 1 < nRespAcc:
        let respPreMax = rc.value.packet.accounts[^2].accHash.to(ItemKey)
        if ivReq.maxPt < respPreMax:
          # Bogus peer returning additional rubbish
          buddy.accFetchRegisterError(forceZombie=true)
          trace recvInfo & " excess accounts", peer, root, reqAcc, nReqAcc,
            respAcc, nRespAcc, respAccPreMax=respPreMax.flStr,
            nRespProof, ela, state, nErrors=buddy.nErrors.fetch.acc
          break body                                # return err()

      # An empty proof can only happen if the accounts cover all of the
      # database for this state root. This is improbable for e,g. a recent
      # state root on `mainnet`. But there is no way that this function
      # will know about that. What will happen when a proof is missing
      # is that the trie `validation()` function will fail at a later
      # stage.

    elif nRespProof == 0:
      # No data available for this state root.
      #
      buddy.registerPeerError(stateRoot)
      trace recvInfo & " not available", peer, root, reqAcc, nReqAcc,
        ela, state, nErrors=buddy.nErrors.fetch.acc
      bodyRc = FetchAccountsResult.err(ENoDataAvailable)
      break body                                    # return err()

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchAccountSnapTimeout < elapsed:
      buddy.accFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.acc = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one/error

    trace recvInfo, peer, root, reqAcc, nReqAcc, respAcc, nRespAcc,
      nRespProof, ela, state, nErrors=buddy.nErrors.fetch.acc

    bodyRc = FetchAccountsResult.ok(rc.value.packet)

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
