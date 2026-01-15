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
  pkg/[chronicles, chronos],
  ../../../wire_protocol,
  ../[helpers, worker_desc]

# ------------------------------------------------------------------------------
# Private function(s)
# ------------------------------------------------------------------------------

proc getBlockHeaders(
    buddy: SnapPeerRef;
    req: BlockHeadersRequest;
      ): Future[Result[FetchHeadersData,SnapError]]
      {.async: (raises: []).} =
  ## Wrapper around `getBlockHeaders()`

  let
    start = Moment.now()
    ethBuddy = buddy.getEthPeer()

  if ethBuddy.isNil:
    return err((EMissingEthContext,"","",Moment.now()-start))

  var resp: BlockHeadersPacket
  try:
    resp = (await ethBuddy.peer.getBlockHeaders(
      req, fetchHeadersRlpxTimeout)).valueOr:
        return err((EGeneric,"","",Moment.now()-start))
  except PeerDisconnected as e:
    return err((EPeerDisconnected,$e.name,$e.msg,Moment.now()-start))
  except CancelledError as e:
    return err((ECancelledError,$e.name,$e.msg,Moment.now()-start))
  except CatchableError as e:
    return err((ECatchableError,$e.name,$e.msg,Moment.now()-start))

  return ok((move resp, Moment.now()-start))

func errStr(rc: Result[FetchHeadersData,SnapError]): string =
  if rc.isErr:
    result = $rc.error.excp
    if 0 < rc.error.name.len:
      result &= "(" & rc.error.name & ")"
    if 0 < rc.error.msg.len:
      result &= "[" & rc.error.msg & "]"
  else:
    result = "n/a"

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

template headerFetch*(
    buddy: SnapPeerRef;
    blockHash: BlockHash;
      ): Result[Header,ErrorType] =
  ## Async/template
  ##
  ## Fetch single header from the network.
  ##
  # Provide template-ready function body
  var bodyRc = Result[Header,ErrorType].err(EGeneric)
  block body:
    const
      sendInfo = trEthSendSendingGetBlockHeaders
      recvInfo = trEthRecvReceivedBlockHeaders
      nReq {.inject,used.} = 1                      # logging only
    let
      peer {.inject,used.} = $buddy.peer            # logging only
      hash {.inject,used.} = blockHash.toStr        # logging only
      req = BlockHeadersRequest(
        maxResults: 1,
        startBlock: BlockHashOrNumber(
          isHash:   true,
          hash:     blockHash.Hash32))

    trace sendInfo, peer, hash, nReq=1

    let rc = await buddy.getBlockHeaders(req)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      debug recvInfo & " error", peer, hash, nReq,
        ela=elapsed.toStr, error=rc.errStr
      bodyRc = typeof(bodyRc).err(rc.error.excp)
      break body                                    # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only

    # Verify result
    let h = rc.value.packet.headers
    if h.len != 1:
      trace recvInfo & " wrong # headers", peer, hash, nReq, nRecv=h.len, ela
      break body                                    # return err()
    let rHash = BlockHash(h[0].computeBlockHash)
    if rHash != blockHash:
      trace recvInfo & " wrong header", peer, hash, nReq,
        recvHash=rHash.toStr, ela
      break body                                    # return err()

    trace recvInfo, peer, hash, nReq, nRecv=1, ela
    bodyRc = typeof(bodyRc).ok(h[0])

  bodyRc # return


template headerFetch*(
    buddy: SnapPeerRef;
    byNumber: BlockNumber;
      ): Result[Header,ErrorType] =
  ## Async/template
  ##
  ## Fetch single header from the network.
  ##
  var bodyRc = Result[Header,ErrorType].err(EGeneric)
  block body:
    const
      sendInfo = trEthSendSendingGetBlockHeaders
      recvInfo = trEthRecvReceivedBlockHeaders
      nReq {.inject,used.} = 1                      # logging only
    let
      peer {.inject,used.} = $buddy.peer            # logging only
      blockNumber {.inject.} = byNumber
      req = BlockHeadersRequest(
        maxResults: 1,
        startBlock: BlockHashOrNumber(
          isHash:   false,
          number:   blockNumber))

    trace sendInfo, peer, blockNumber, nReq=1

    let rc = await buddy.getBlockHeaders(req)
    var elapsed: Duration
    if rc.isOk:
      elapsed = rc.value.elapsed
    else:
      elapsed = rc.error.elapsed
      debug recvInfo & " error", peer, blockNumber, nReq,
        ela=elapsed.toStr, error=rc.errStr
      bodyRc = typeof(bodyRc).err(rc.error.excp)
      break body                                    # return err()

    let
      ela {.inject,used.} = elapsed.toStr           # logging only

    # Verify result
    let h = rc.value.packet.headers
    if h.len != 1:
      trace recvInfo & " wrong # headers", peer, blockNumber, nReq,
        nRecv=h.len, ela
      break body                                    # return err()
    if h[0].number != blockNumber:
      trace recvInfo & " wrong header", peer, blockNumber, nReq, ela
      break body                                    # return err()

    trace recvInfo, peer, blockNumber, nReq, nRecv=1, ela
    bodyRc = typeof(bodyRc).ok(h[0])

  bodyRc # return

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
