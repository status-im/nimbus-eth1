# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/options,
  chronos,
  eth/[common, p2p],
  stew/byteutils,
  "../../.."/[protocol, types],
  ../../worker_desc,
  ./com_error

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# proc getBlockHeader*(
#     buddy: SnapBuddyRef;
#     num: BlockNumber;
#       ): Future[Result[BlockHeader,ComError]]
#       {.async.} =
#   ## Get single block header
#   let
#     peer = buddy.peer
#     reqLen = 1u
#     hdrReq = BlocksRequest(
#       startBlock: HashOrNum(
#         isHash:   false,
#         number:   num),
#       maxResults: reqLen,
#       skip:       0,
#       reverse:    false)
#
#   trace trEthSendSendingGetBlockHeaders, peer, header=("#" & $num), reqLen
#
#   var hdrResp: Option[blockHeadersObj]
#   try:
#     hdrResp = await peer.getBlockHeaders(hdrReq)
#   except CatchableError as e:
#     trace trSnapRecvError & "waiting for GetByteCodes reply", peer,
#       error=e.msg
#     return err(ComNetworkProblem)
#
#   var hdrRespLen = 0
#   if hdrResp.isSome:
#     hdrRespLen = hdrResp.get.headers.len
#   if hdrRespLen == 0:
#     trace trEthRecvReceivedBlockHeaders, peer, reqLen, respose="n/a"
#     return err(ComNoHeaderAvailable)
#
#   if hdrRespLen == 1:
#     let
#       header = hdrResp.get.headers[0]
#       blockNumber = header.blockNumber
#     trace trEthRecvReceivedBlockHeaders, peer, hdrRespLen, blockNumber
#     return ok(header)
#
#   trace trEthRecvReceivedBlockHeaders, peer, reqLen, hdrRespLen
#   return err(ComTooManyHeaders)


proc getBlockHeader*(
    buddy: SnapBuddyRef;
    hash: Hash256;
      ): Future[Result[BlockHeader,ComError]]
      {.async.} =
  ## Get single block header
  let
    peer = buddy.peer
    reqLen = 1u
    hdrReq = BlocksRequest(
      startBlock: HashOrNum(
        isHash:   true,
        hash:     hash),
      maxResults: reqLen,
      skip:       0,
      reverse:    false)

  trace trEthSendSendingGetBlockHeaders, peer,
    header=hash.data.toHex, reqLen

  var hdrResp: Option[blockHeadersObj]
  try:
    hdrResp = await peer.getBlockHeaders(hdrReq)
  except CatchableError as e:
    trace trSnapRecvError & "waiting for GetByteCodes reply", peer,
      error=e.msg
    return err(ComNetworkProblem)

  var hdrRespLen = 0
  if hdrResp.isSome:
    hdrRespLen = hdrResp.get.headers.len
  if hdrRespLen == 0:
    trace trEthRecvReceivedBlockHeaders, peer, reqLen, respose="n/a"
    return err(ComNoHeaderAvailable)

  if hdrRespLen == 1:
    let
      header = hdrResp.get.headers[0]
      blockNumber = header.blockNumber
    trace trEthRecvReceivedBlockHeaders, peer, hdrRespLen, blockNumber
    return ok(header)

  trace trEthRecvReceivedBlockHeaders, peer, reqLen, hdrRespLen
  return err(ComTooManyHeaders)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
