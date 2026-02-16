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
  ../../../wire_protocol,
  ../[helpers, state_db, worker_desc],
  ./storage_helpers

type
  FetchStorageResult* = Result[StorageRangesData,ErrorType]
    ## Shortcut

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc registerPeerError(buddy: SnapPeerRef; root: StateRoot; slowPeer=false) =
  ## Do not repeat the same time-consuming failed request for the same state
  ## root.
  buddy.stoFetchRegisterError(slowPeer)
  buddy.only.failedReq.stateRoot.put(root,0u8)

proc maybeSlowPeerError(buddy: SnapPeerRef; ela: Duration; root: StateRoot) =
  ## Register slow response, definitely not fast enough
  if fetchStorageSnapTimeout <= ela:
    buddy.registerPeerError(root, slowPeer=true)
  else:
    buddy.stoFetchRegisterError()


proc getStorage(
    buddy: SnapPeerRef;
    req: StorageRangesRequest;
      ): Future[Result[FetchStorageData,SnapError]]
      {.async: (raises: []).} =
  ## Wrapper around `getStorageRanges()`
  let start = Moment.now()

  buddy.only.failedReq.stateRoot.peek(StateRoot(req.rootHash)).isErrOr:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

  var resp: StorageRangesPacket
  try:
    resp = (await buddy.peer.getStorageRanges(
                    req, fetchStorageSnapTimeout)).valueOr:
        return err((EGeneric,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  return ok((move resp, Moment.now()-start))


func errStr(rc: Result[FetchStorageData,SnapError]): string =
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

template fetchStorage*(
    buddy: SnapPeerRef;
    stateRoot: StateRoot;                           # DB state
    accounts: seq[ItemKey];                         # List of accounts
    ivReq = ItemKeyRangeMax;                        # Range (if any)
      ): FetchStorageResult =
  ## Async/template
  ##
  ## Fetch storage slots from the network.
  ##
  var bodyRc = FetchStorageResult.err(EGeneric)
  block body:
    const
      sendInfo = trSnapSendSendingGetStorageRanges
      recvInfo = trSnapRecvReceivedStorageRanges
    var
      stoData: StorageRangesData                    # `Result[]` payload
    let
      nReqAcc {.inject.} = accounts.len
      fetchReq = StorageRangesRequest(
        rootHash:      stateRoot.Hash32,
        accountHashes: accounts.to(seq[Hash32]),
        startingHash:  ivReq.minPt.to(Hash32),
        limitHash:     ivReq.maxPt.to(Hash32),
        responseBytes: fetchStorageSnapBytesLimit)
      peer {.inject,used.} = $buddy.peer            # logging only
      root {.inject,used.} = stateRoot.toStr        # logging only
      reqSto {.inject,used.} = ivReq.flStr          # logging only
      nReqSto {.inject,used.} = ivReq.lenStr        # logging only

    # Verify consistency as received from caller
    doAssert 0 < accounts.len
    if ivReq != ItemKeyRangeMax and accounts.len != 1:
      raiseAssert "Oops" &
        ", iv=" & reqSto &
        ", iv.len=" & nReqSto &
        ", nAccounts=" & $accounts.len

    trace sendInfo, peer, root, nReqAcc, reqSto, nReqSto,
      state=($buddy.syncState), nErrors=buddy.nErrors.fetch.sto

    let rc = await buddy.getStorage(fetchReq)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      bodyRc = FetchStorageResult.err(rc.error.excp)
      block evalError:
        case rc.error.excp:
        of EGeneric:
          break evalError
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, root, nReqAcc, reqSto, nReqSto,
            ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.sto
          break body                                # return err()
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.sto.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.stoFetchRegisterError()
        of ENoDataAvailable, EMissingEthContext:
          # Not allowed here -- internal error
          raiseAssert "Unexpected error " & $rc.error.excp

        # Debug message for other errors
        debug recvInfo & " error", peer, root, nReqAcc, reqSto, nReqSto,
          ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.sto
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      state {.inject,used.} = $buddy.syncState      # logging only

    # Evaluate error result (if any)
    if rc.isErr or buddy.ctrl.stopped:
      buddy.maybeSlowPeerError(elapsed, stateRoot)
      trace recvInfo & " error", peer, root, nReqAcc, reqSto, nReqSto,
        ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.sto
      break body                                    # return err()

    # Check against obvious protocol violations
    let
      nRespSlots {.inject.} = rc.value.packet.slots.len
      nRespProof {.inject.} = rc.value.packet.proof.len

    if 0 < nRespSlots:
      if nReqAcc < nRespSlots:
        # Protocol violation
        buddy.registerPeerError(stateRoot)
        trace recvInfo & " more slots than requested", peer, root, nReqAcc,
          reqSto, nReqSto, nRespSlots, nRespProof,
          ela, state, nErrors=buddy.nErrors.fetch.sto
        break body                                  # return err()

      let
        nTop = nRespSlots - 1                       # Index of last slot
        slot = rc.value.packet.slots[nTop]          # Last slot

      # Check by item. Only the last slot might be incomplete and needs a
      # proof. This is handles below somewhere in the next `if` clauses.
      stoData.slots.setLen(nTop)                    # pre-set without last slot
      for n in 0 ..< nTop:
        if rc.value.packet.slots[n].len == 0:
          # Protocol violation
          buddy.registerPeerError(stateRoot)
          trace recvInfo & " error empty slot", peer, root, nReqAcc,
            reqSto, inx=n, nReqSto, nRespSlots=($nRespSlots & "+1"), nRespProof,
            ela, state, nErrors=buddy.nErrors.fetch.sto
          break body                                # return err()
        stoData.slots[n] = rc.value.packet.slots[n]

      # There was a `doAssert` at the beginning of this template that made
      # sure that there is a range request only when `nRespSlots == 1`.
      if nRespSlots == 1:                           # => `nTop == 0`
        if 0 < slot.len:
          let
            slMin = slot[0].slotHash.to(ItemKey)
            slMax = slot[^1].slotHash.to(ItemKey)
            respSlot {.inject,used.} = (slMin,slMax).flStr # logging only

          if slMin < ivReq.minPt:
            trace recvInfo & " min slot item too low", peer, root, nReqAcc,
              reqSto, nReqSto, nRespSlots="0+1", nRespProof,
              ela, state, nErrors=buddy.nErrors.fetch.sto
            break body                            # return err()

          # According to specs, the peer must respond with at least one slot
          # value. If there is no account in the requested range, then the next
          # account beyond is to be returned. This leads to implementations
          # like `Geth` to always return the next slot beyond the requested
          # range regardless of the number of slots within.
          if 1 < slot.len:
            let respPreMax = slot[^2].slotHash.to(ItemKey)
            if ivReq.maxPt < respPreMax:
              # Bogus peer returning additional rubbish
              buddy.stoFetchRegisterError(forceZombie=true)
              trace recvInfo & " excess slots", peer, root, nReqAcc,
                reqSto, nReqSto, nRespSlots="0+1", respSlot,
                respSlotPreMax=respPreMax.flStr, nRespProof,
                ela, state, nErrors=buddy.nErrors.fetch.sto
              break body                          # return err()

        elif nRespProof == 0:
          # Protocol violation. It is not allowed to return an empty
          # slot + empty proof. The caller is obliged to make sure that the
          # account has a non-empty storage root.
          buddy.registerPeerError(stateRoot)
          trace recvInfo & " error empty slot & proof", peer, root, nReqAcc,
            reqSto, nReqSto, nRespSlots, nRespProof,
            ela, state, nErrors=buddy.nErrors.fetch.sto
          break body                              # return err()

      # Add last item and proof
      if rc.value.packet.proof.len == 0:
         stoData.slots.add slot
      else:
        stoData.slot = slot
        stoData.proof = rc.value.packet.proof

    elif nRespProof == 0:
      # Both, proof + slots are empty. This means that there is no storage
      # data available for this state root.
      buddy.registerPeerError(stateRoot)
      trace recvInfo & " not available", peer, root, nReqAcc, reqSto,
        nReqSto, ela, state, nErrors=buddy.nErrors.fetch.sto
      bodyRc = FetchStorageResult.err(ENoDataAvailable)
      break body                                  # return err()

    elif ivReq != ItemKeyRangeMax:
      # So `nReqAcc == 1` and `0 < nRespProof`. This implies that the proof
      # will/must show that there are no slot items, anymore.
      #
      # This is usually returned instead of a single, empty response slot.
      #
      stoData.proof = rc.value.packet.proof

    else:
      # This makes no sense:
      #
      # * ivReq.len == max-size
      # * nRespSlots == 0
      # * nRespProof != 0
      #
      # It would mean that the for last requested account, in the response
      # there are no slot items (as `nRespSlots == 0`.) But there is a
      # (non-empty) proof for that. But without slot items, there cannot be
      # any such proof in the first place.
      #
      buddy.registerPeerError(stateRoot)
      trace recvInfo & " protocol violation", peer, root, nReqAcc,
        reqSto, nReqSto, nRespSlots, nRespProof,
        ela, state, nErrors=buddy.nErrors.fetch.sto
      break body                                  # return err()

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchStorageSnapTimeout < elapsed:
      buddy.stoFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.sto = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one/error

    trace recvInfo, peer, root, nReqAcc, reqSto, nReqSto,
      nRespSlots=($stoData.slots.len & "+" & $(0 < stoData.slot.len).ord),
      nRespProof, ela, state, nErrors=buddy.nErrors.fetch.sto

    bodyRc = FetchStorageResult.ok(stoData)

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
