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

{.used.}                                            # FIXME -- will go away

import
  std/[strutils, typetraits],
  pkg/[chronicles, chronos, minilru, stew/byteutils],
  ../../../../wire_protocol,
  ../../[helpers, state_db, worker_desc],
  ./trie_node_helpers

type
  FetchTrieNodeResult* = Result[TrieNodesPacket,ErrorType]
    ## Shortcut

  PerAccStoPaths* = tuple
    acc: seq[byte]                                  # Account path
    paths: seq[seq[byte]]                           # Slots to be fetched

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc registerPeerError(buddy: SnapPeerRef; path: seq[byte]; slowPeer=false) =
  ## Do not repeat the same time-consuming failed request
  buddy.triFetchRegisterError(slowPeer)
  buddy.only.failedReq.accPath.put(path,0u8)

proc maybeSlowPeerError(buddy: SnapPeerRef; ela: Duration; path: seq[byte]) =
  ## Register slow response, definitely not fast enough
  if fetchTrieNodeSnapTimeout <= ela:
    buddy.registerPeerError(path, slowPeer=true)
  else:
    buddy.triFetchRegisterError()


proc getTrieNodes(
    buddy: SnapPeerRef;
    req: TrieNodesRequest;
      ): Future[Result[FetchTrieNodesData,SnapError]]
      {.async: (raises: []).} =
  ## Wrapper around `getTrieNodeRange()`
  let start = Moment.now()

  buddy.only.failedReq.accPath.peek(req.paths[0][0].distinctBase).isErrOr:
    return err((EAlreadyTriedAndFailed,"","",Moment.now()-start))

  var resp: TrieNodesPacket
  try:
    resp = (await buddy.peer.getTrieNodes(
                    req, fetchTrieNodeSnapTimeout)).valueOr:
        return err((EGeneric,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  return ok((move resp, Moment.now()-start))


func errStr(rc: Result[FetchTrieNodesData,SnapError]): string =
  if rc.isErr:
    result = $rc.error.excp
    if 0 < rc.error.name.len:
      result &= "(" & rc.error.name & ")"
    if 0 < rc.error.msg.len:
      result &= "[" & rc.error.msg & "]"
  else:
    result = "n/a"

proc toStr(path: openArray[byte]): string =
  let
    p = path.toHex.replace("0x","")
    w = if p.len <= 14: p
        else: p.substr(0,7) & ".." & p.substr(p.len-4)
  w & "#" & $p.len

# ------------------------------------------------------------------------------
# Public function
# ------------------------------------------------------------------------------

template fetchAccTrieNodes*(
    buddy: SnapPeerRef;
    stateRoot: StateRoot;                           # DB state
    accPaths: openArray[seq[byte]];                 # Accounts to be fetched
      ): auto =
  ## Async/template
  ##
  ## Fetch accounts trie nodes from the network.
  ##
  var bodyRc = FetchTrieNodeResult.err(EGeneric)
  block body:
    const
      sendInfo = trSnapSendSendingGetTrieNodes
      recvInfo = trSnapRecvReceivedTrieNodes

    let
      nReqAcc {.inject.} = accPaths.len
      fetchReq = TrieNodesRequest(
        rootHash: stateRoot.Hash32,
        paths:    @[cast[seq[AccountOrSlotPath]](accPaths)],
        bytes:    fetchTrieNodeSnapBytesLimit)

      root {.inject,used.} = stateRoot.toStr        # logging only
      peer {.inject,used.} = $buddy.peer            # logging only
      firstAcc {.inject,used.} = accPaths[0].toStr  # logging only

    trace sendInfo, peer, root, firstAcc, nReqAcc, syncState=($buddy.syncState),
      nErrors=buddy.nErrors.fetch.tri

    let rc = await buddy.getTrieNodes(fetchReq)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      bodyRc = typeof(bodyRc).err(rc.error.excp)
      block evalError:
        case rc.error.excp:
        of EGeneric:
          break evalError
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, root, firstAcc, nReqAcc,
            ela=elapsed.toStr, syncState=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.tri
          break body                                # return err()
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.tri.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.triFetchRegisterError()
        of ENoDataAvailable, EMissingEthContext, ETrieError, ELockError,
           ECacheError, ECompleted:
          # Not allowed here -- internal error
          raiseAssert "Unexpected error " & $rc.error.excp

        # Debug message for other errors
        debug recvInfo & " error", peer, root, firstAcc, nReqAcc,
          ela=elapsed.toStr, syncState=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.tri
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      syncState {.inject,used.} = $buddy.syncState  # logging only

    # Evaluate error result (if any)
    if rc.isErr or buddy.ctrl.stopped:
      buddy.maybeSlowPeerError(elapsed, accPaths[0])
      trace recvInfo & " error", peer, root, firstAcc, nReqAcc,
        ela, syncState, error=rc.errStr, nErrors=buddy.nErrors.fetch.tri
      break body                                    # return err()

    # Check against obvious protocol violations
    let nRespAcc {.inject.} = rc.value.packet.nodes.len

    if nRespAcc == 0:
      # No data available for this accounts list
      #
      buddy.registerPeerError(accPaths[0])
      trace recvInfo & " not available", peer, root, firstAcc, nReqAcc,
        ela, syncState, nErrors=buddy.nErrors.fetch.tri
      bodyRc = typeof(bodyRc).err(ENoDataAvailable)
      break body                                    # return err()
    elif nReqAcc < nRespAcc:
      # Bogus peer returning additional rubbish
      buddy.triFetchRegisterError(forceZombie=true)
      trace recvInfo & " excess account paths", peer, root, firstAcc, nReqAcc,
        nRespAcc, ela, syncState, nErrors=buddy.nErrors.fetch.tri
      break body                                    # return err()

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchTrieNodeSnapTimeout < elapsed:
      buddy.triFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.tri = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one/error

    trace recvInfo, peer, root, firstAcc, nReqAcc, nRespAcc,
      ela, syncState, nErrors=buddy.nErrors.fetch.tri

    bodyRc = typeof(bodyRc).ok(rc.value.packet)

  bodyRc

template fetchStoTrieNodes*(
    buddy: SnapPeerRef;
    stateRoot: StateRoot;                           # DB state
    perAccPaths: openArray[PerAccStoPaths];         # Slots to be fetched
      ): auto =
  ## Async/template
  ##
  ## Fetch accounts trie nodes from the network.
  ##
  var bodyRc = FetchTrieNodeResult.err(EGeneric)
  block body:
    const
      sendInfo = trSnapSendSendingGetTrieNodes
      recvInfo = trSnapRecvReceivedTrieNodes

    let
      nReqSto {.inject.} = perAccPaths.len
      firstAccPath = perAccPaths[0].acc

      root {.inject,used.} = stateRoot.toStr        # logging only
      peer {.inject,used.} = $buddy.peer            # logging only
      firstAcc {.inject,used.} = firstAccPath.toStr # logging only

    var fetchReq = TrieNodesRequest(
      rootHash: stateRoot.Hash32,
      bytes:    fetchTrieNodeSnapBytesLimit)

    for w in perAccPaths:
      let paths = @[w.acc] & @[w.paths]
      fetchReq.paths.add cast[seq[seq[AccountOrSlotPath]]](paths)

    trace sendInfo, peer, root, firstAcc, nReqSto, syncState=($buddy.syncState),
      nErrors=buddy.nErrors.fetch.tri

    let rc = await buddy.getTrieNodes(fetchReq)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      bodyRc = typeof(bodyRc).err(rc.error.excp)
      block evalError:
        case rc.error.excp:
        of EGeneric:
          break evalError
        of EAlreadyTriedAndFailed:
          trace recvInfo & " error", peer, root, firstAcc, nReqSto,
            ela=elapsed.toStr, syncState=($buddy.syncState), error=rc.errStr,
            nErrors=buddy.nErrors.fetch.tri
          break body                                # return err()
        of EPeerDisconnected, ECancelledError:
          buddy.nErrors.fetch.tri.inc
          buddy.ctrl.zombie = true
        of ECatchableError:
          buddy.triFetchRegisterError()
        of ENoDataAvailable, EMissingEthContext, ETrieError, ELockError,
           ECacheError, ECompleted:
          # Not allowed here -- internal error
          raiseAssert "Unexpected error " & $rc.error.excp

        # Debug message for other errors
        debug recvInfo & " error", peer, root, firstAcc, nReqSto,
          ela=elapsed.toStr, syncState=($buddy.syncState), error=rc.errStr,
          nErrors=buddy.nErrors.fetch.tri
        break body                                  # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only
      syncState {.inject,used.} = $buddy.syncState  # logging only

    # Evaluate error result (if any)
    if rc.isErr or buddy.ctrl.stopped:
      buddy.maybeSlowPeerError(elapsed, firstAccPath)
      trace recvInfo & " error", peer, root, firstAcc, nReqSto,
        ela, syncState, error=rc.errStr, nErrors=buddy.nErrors.fetch.tri
      break body                                    # return err()

    # Check against obvious protocol violations
    let nRespSto {.inject.} = rc.value.packet.nodes.len

    if nRespSto == 0:
      # No data available for this accounts list
      #
      buddy.registerPeerError(firstAccPath)
      trace recvInfo & " not available", peer, root, firstAcc, nReqSto,
        ela, syncState, nErrors=buddy.nErrors.fetch.tri
      bodyRc = typeof(bodyRc).err(ENoDataAvailable)
      break body                                    # return err()
    elif nReqSto < nRespSto:
      # Bogus peer returning additional rubbish
      buddy.triFetchRegisterError(forceZombie=true)
      trace recvInfo & " excess account paths", peer, root, firstAcc, nReqSto,
        nRespSto, ela, syncState, nErrors=buddy.nErrors.fetch.tri
      break body                                    # return err()

    # Ban an overly slow peer for a while when observed consecutively.
    if fetchTrieNodeSnapTimeout < elapsed:
      buddy.triFetchRegisterError(slowPeer=true)
    else:
      buddy.nErrors.fetch.tri = 0                   # reset error count
      buddy.ctx.pool.lastSlowPeer = Opt.none(Hash)  # not last one/error

    trace recvInfo, peer, root, firstAcc, nReqSto, nRespSto,
      ela, syncState, nErrors=buddy.nErrors.fetch.tri

    bodyRc = typeof(bodyRc).ok(rc.value.packet)

  bodyRc

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
