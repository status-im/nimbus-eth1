# fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[sequtils, json],
  json_rpc/rpcserver,
  json_serialization/std/tables,
  stew/byteutils,
  ../network/wire/portal_protocol,
  ../network/state/state_content,
  ./rpc_types

{.warning[UnusedImport]: off.}
import json_rpc/errors

export rpcserver, tables

# Portal Network JSON-RPC impelentation as per specification:
# https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc

const
  ContentNotFoundError = (code: -39001, msg: "Content not found")
  ContentNotFoundErrorWithTrace = (code: -39002, msg: "Content not found")

type ContentInfo = object
  content: string
  utpTransfer: bool

ContentInfo.useDefaultSerializationIn JrpcConv
TraceContentLookupResult.useDefaultSerializationIn JrpcConv
TraceObject.useDefaultSerializationIn JrpcConv
NodeMetadata.useDefaultSerializationIn JrpcConv
TraceResponse.useDefaultSerializationIn JrpcConv

# Note:
# Using a string for the network parameter will give an error in the rpc macro:
# Error: Invalid node kind nnkInfix for macros.`$`
# Using a static string works but some sandwich problem seems to be happening,
# as the proc becomes generic, where the rpc macro from router.nim can no longer
# be found, which is why we export rpcserver which should export router.
proc installPortalBeaconApiHandlers*(rpcServer: RpcServer, p: PortalProtocol) =
  let
    invalidKeyErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")
    invalidValueErr =
      (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content value")

  rpcServer.rpc("portal_beaconFindContent") do(
    enr: Record, contentKey: string
  ) -> JsonString:
    let
      node = toNodeWithAddress(enr)
      foundContentResult =
        await p.findContent(node, ContentKeyByteList.init(hexToSeqByte(contentKey)))

    if foundContentResult.isErr():
      raise newException(ValueError, $foundContentResult.error)
    else:
      let foundContent = foundContentResult.get()
      case foundContent.kind
      of Content:
        let res = ContentInfo(
          content: foundContent.content.to0xHex(), utpTransfer: foundContent.utpTransfer
        )
        return JrpcConv.encode(res).JsonString
      of Nodes:
        let enrs = foundContent.nodes.map(
          proc(n: Node): Record =
            n.record
        )
        let jsonEnrs = JrpcConv.encode(enrs)
        return ("{\"enrs\":" & jsonEnrs & "}").JsonString

  rpcServer.rpc("portal_beaconOffer") do(
    enr: Record, contentKey: string, contentValue: string
  ) -> string:
    let
      node = toNodeWithAddress(enr)
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKV = ContentKV(contentKey: ContentKeyByteList.init(key), content: content)
      res = await p.offer(node, @[contentKV])

    if res.isOk():
      return SSZ.encode(res.get()).to0xHex()
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_beaconRecursiveFindContent") do(
    contentKey: string
  ) -> ContentInfo:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      contentResult = (await p.contentLookup(key, contentId)).valueOr:
        raise (ref ApplicationError)(
          code: ContentNotFoundError.code, msg: ContentNotFoundError.msg
        )

    return ContentInfo(
      content: contentResult.content.to0xHex(), utpTransfer: contentResult.utpTransfer
    )

  rpcServer.rpc("portal_beaconTraceRecursiveFindContent") do(
    contentKey: string
  ) -> TraceContentLookupResult:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      res = await p.traceContentLookup(key, contentId)

    # TODO: Might want to restructure the lookup result here. Potentially doing
    # the json conversion in this module.
    if res.content.isSome():
      return res
    else:
      let data = Opt.some(JrpcConv.encode(res.trace).JsonString)
      raise (ref ApplicationError)(
        code: ContentNotFoundErrorWithTrace.code,
        msg: ContentNotFoundErrorWithTrace.msg,
        data: data,
      )

  rpcServer.rpc("portal_beaconStore") do(
    contentKey: string, contentValue: string
  ) -> bool:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentValueBytes = hexToSeqByte(contentValue)
      contentId = p.toContentId(key)

    if contentId.isSome():
      p.storeContent(key, contentId.get(), contentValueBytes)
      return true
    else:
      raise invalidKeyErr

  rpcServer.rpc("portal_beaconLocalContent") do(contentKey: string) -> string:
    let
      key = ContentKeyByteList.init(hexToSeqByte(contentKey))
      contentId = p.toContentId(key).valueOr:
        raise (ref errors.InvalidRequest)(code: -32602, msg: "Invalid content key")

      contentResult = p.dbGet(key, contentId).valueOr:
        raise (ref ApplicationError)(
          code: ContentNotFoundError.code, msg: ContentNotFoundError.msg
        )

    return contentResult.to0xHex()

  rpcServer.rpc("portal_beaconGossip") do(
    contentKey: string, contentValue: string
  ) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ContentKeyByteList.init(key)])
      numberOfPeers =
        await p.neighborhoodGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers

  rpcServer.rpc("portal_beaconRandomGossip") do(
    contentKey: string, contentValue: string
  ) -> int:
    let
      key = hexToSeqByte(contentKey)
      content = hexToSeqByte(contentValue)
      contentKeys = ContentKeysList(@[ContentKeyByteList.init(key)])
      numberOfPeers = await p.randomGossip(Opt.none(NodeId), contentKeys, @[content])

    return numberOfPeers
