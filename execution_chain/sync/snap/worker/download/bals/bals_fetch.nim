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
  ../../[helpers, worker_desc],
  ./[bals_fetch_eth, bals_fetch_snap, bals_helpers]

logScope:
  topics = "snap sync"

# Borrow from beacon syncer
from ../../../../beacon/worker/blocks/blocks_fetch_bal
  import decodeBlockAccessList
export
  decodeBlockAccessList

const
  emptyRawBal = seq[RawBlockAccessList].default
    ## Shortcut

type
  FetchBalResult* = tuple
    bal: seq[RawBlockAccessList]
    peerID: Hash

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc registerPeerError(buddy: SnapPeerRef, firstHash: Hash32, slowPeer=false) =
  ## Do not repeat the same time-consuming failed request
  buddy.balFetchRegisterError(slowPeer)
  buddy.only.failedReq.balHash = firstHash

proc maybeSlowPeerError(buddy: SnapPeerRef, ela: Duration, firstHash: Hash32) =
  ## Register slow response, definitely not fast enough
  if fetchBalRlpxTimeout <= ela:
    buddy.registerPeerError(firstHash, slowPeer=true)

    # Do not repeat the same time-consuming failed request
    buddy.only.failedReq.balHash = firstHash
  else:
    buddy.balFetchRegisterError()

func errStr(rc: Result[FetchBalData,SnapErrorEx]): string =
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

template fetchBlockAccessLists*(
    buddy: SnapPeerRef;
    request: openArray[Hash32];                     # list of block hashes
    startInx: int;                                  # start at this entry
      ): auto =
  ## Async/template
  ##
  ## Fetch BALs from the network.
  ##
  var bodyRc = Result[FetchBalResult,ErrorType].err(EGeneric)
  block body:
    doAssert startInx < request.len

    const
      sendEthInfo = trEthSendSendingGetBals
      recvEthInfo = trEthRecvReceivedBals
      sendSnapInfo = trSnapSendSendingGetBals
      recvSnapInfo = trSnapRecvReceivedBals
    var
      peer {.inject,used.} = $buddy.peer            # logging only

    let nReq {.inject.} = request.len - startInx
    if nReq <= 0:
      if buddy.only.supportsBal:
        debug sendSnapInfo & " empty request", peer, state=($buddy.syncState),
          nErrors=buddy.nErrors.fetch.bal
      else:
        debug sendEthInfo & " empty request", state=($buddy.syncState),
          nErrors=buddy.nErrors.fetch.bal
      bodyRc = typeof(bodyRc).ok((emptyRawBal,Hash 0))
      break body

    let startHash {.inject.} = request[startInx]
    if buddy.only.supportsBal:
      debug sendSnapInfo, peer, startHash=startHash.short, nReq,
        nErrors=buddy.nErrors.fetch.bal, firstInx=startInx, nHashes=request.len
    else:
      debug sendEthInfo, startHash=startHash.short, nReq,
        nErrors=buddy.nErrors.fetch.bal, firstInx=startInx, nHashes=request.len

    var rc: Result[FetchBalData,SnapErrorEx]
    if buddy.only.supportsBal:
      let req = SnapBalRequest(
        blockHashes: request[startInx .. ^1],
        bytes:       nFetchBalSnapSizeMax)
      rc = await buddy.snapGetBals(req)
    else:
      let req = BlockAccessListsRequest(
        blockHashes: request[startInx .. ^1])
      rc = await buddy.ethGetBals(req)

    var
      elapsed: Duration
      peerID: Hash
    if rc.isOk:
      (elapsed, peerID) = (rc.value.elapsed, rc.value.peerID)
    else:
      (elapsed, peerID) = (rc.error.elapsed, rc.error.peerID)
      block evalError:
        bodyRc = typeof(bodyRc).err(rc.error.excp)
        case rc.error.excp:
        of EGeneric:
          if buddy.only.supportsBal:                # supported by `buddy`?
            break evalError
        of EAlreadyTriedAndFailed:
          if buddy.only.supportsBal:
            trace recvSnapInfo & " error", peer, startHash=startHash.short,
              nReq, ela=elapsed.toStr, state=($buddy.syncState),
              error=rc.errStr, nErrors=buddy.nErrors.fetch.bal
          else:
            trace recvEthInfo & " error", startHash=startHash.short,
              nReq, ela=elapsed.toStr, state=($buddy.syncState),
              error=rc.errStr, nErrors=buddy.nErrors.fetch.bal
          break body                                # return err()
        of EPeerDisconnected, ECancelledError:
          if buddy.only.supportsBal:                # supported by `buddy`?
            buddy.nErrors.fetch.bal.inc             # `buddy` error handling
            buddy.ctrl.zombie = true
        of ECatchableError:
          if buddy.only.supportsBal:                # supported by `buddy`?
            buddy.balFetchRegisterError()           # `buddy` error handling
        of EMissingEthContext:
          if buddy.only.supportsBal:
            trace recvSnapInfo & " error eth peers missing", peer,
              startHash=startHash.short, nReq, ela=elapsed.toStr,
              state=($buddy.syncState), error=rc.errStr
          else:
            trace recvEthInfo & " error eth peers missing",
              startHash=startHash.short, nReq, ela=elapsed.toStr,
              state=($buddy.syncState), error=rc.errStr
          break body
        of EUnusedForFetch:
          # Not allowed here -- internal error
          raiseAssert "Unexpected fetch error " & $rc.error.excp

        # Debug message for other errors
        if buddy.only.supportsBal:
          debug recvSnapInfo & " error", peer, startHash=startHash.short, nReq,
            ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.bal
        else:
          debug recvEthInfo & " error", startHash=startHash.short, nReq,
            ela=elapsed.toStr, state=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.bal

        if not buddy.only.supportsBal:              # borrowed from `eth`?
          buddy.ctx.pool.failedEthBalId.put(peerID, zeroHash32)
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      state {.inject,used.} = $buddy.syncState      # logging only

    # Evaluate result
    if rc.isErr or buddy.ctrl.stopped:
      if buddy.only.supportsBal:                    # supported by `buddy`
        buddy.maybeSlowPeerError(elapsed, startHash)
        trace recvSnapInfo & " error", peer, startHash=startHash.short, nReq,
          ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.bal
      else:
        trace recvEthInfo & " error", startHash=startHash.short, nReq,
          ela, state, error=rc.errStr, nErrors=buddy.nErrors.fetch.bal
      break body                                    # return err()

    # Verify the correct number of BALs received
    template b: auto = rc.value.packet.accessLists
    if b.len == 0 or nReq < b.len:
      if not buddy.only.supportsBal:              # borrowed from `eth`?
        # Cannot do musch but ignoring this `eth` peer for `startHash`
        buddy.ctx.pool.failedEthBalId.put(peerID, zeroHash32)
      elif nReq < b.len:
        # Bogus peer returning additional rubbish
        buddy.balFetchRegisterError(forceZombie=true)
      else:
        # No data available
        buddy.maybeSlowPeerError(elapsed, startHash)

      if buddy.only.supportsBal:
        trace recvSnapInfo & " error", peer, startHash=startHash.short, nReq,
          nResp=b.len, ela, state, nErrors=buddy.nErrors.fetch.bal
      else:
        trace recvEthInfo & " error", startHash=startHash.short, nReq,
          nResp=b.len, ela, state, nErrors=buddy.nErrors.fetch.bal
      break body                                    # return err()

    if buddy.only.supportsBal:
      # Request did not fail (for now)
      buddy.only.failedReq.balHash = zeroHash32

      # Ban an overly slow peer for a while when observed consecutively.
      if fetchBalErrTimeout < elapsed:
        buddy.balFetchRegisterError(slowPeer=true)
      else:
        buddy.nErrors.fetch.bal = 0                 # reset error count
        buddy.ctx.pool.lastSlowPeer = Opt.none(Hash) # not last one or not error

    else:                                           # borrowed from `eth`
      if fetchBalErrTimeout < elapsed:
        # Cannot do much but ignoring this `eth` peer for `startHash`
        buddy.maybeSlowPeerError(elapsed, startHash)
      else:
        # Request did not fail
        buddy.ctx.pool.failedEthBalId.del(peerID)   # reset error count

    if buddy.only.supportsBal:
      trace recvSnapInfo, peer, startHash=startHash.short, nReq, nResp=b.len,
        ela, state, nErrors=buddy.nErrors.fetch.bal
    else:
      trace recvEthInfo, startHash=startHash.short, nReq, nResp=b.len,
        ela, state, nErrors=buddy.nErrors.fetch.bal

    bodyRc = typeof(bodyRc).ok((b,peerID))

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
