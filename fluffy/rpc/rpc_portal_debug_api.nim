# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_rpc/[rpcproxy, rpcserver], stew/byteutils,
  ../network/wire/portal_protocol,
  ".."/[content_db, seed_db]

export rpcserver

# Some RPCs that are (currently) useful for testing & debugging
proc installPortalDebugApiHandlers*(
    rpcServer: RpcServer|RpcProxy, p: PortalProtocol, network: static string)
    {.raises: [Defect, CatchableError].} =

  rpcServer.rpc("portal_" & network & "_store") do(
      contentKey: string, content: string) -> bool:
    let key = ByteList.init(hexToSeqByte(contentKey))
    let contentId = p.toContentId(key)

    if contentId.isSome():
      p.storeContent(contentId.get(), hexToSeqByte(content))

      return true
    else:
      raise newException(ValueError, "Invalid content key")

  rpcServer.rpc("portal_" & network & "_storeContent") do(
      dataFile: string) -> bool:
    let res = p.historyStore(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagate") do(
      dataFile: string) -> bool:
    let res = await p.historyPropagate(dataFile)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_propagateBlock") do(
      dataFile: string, blockHash: string) -> bool:
    let res = await p.historyPropagateBlock(dataFile, blockHash)
    if res.isOk():
      return true
    else:
      raise newException(ValueError, $res.error)

  rpcServer.rpc("portal_" & network & "_storeContentInNodeRange") do(
      dbPath: string,
      max: uint32,
      starting: uint32) -> bool:

    let storeResult = p.storeContentInNodeRange(dbPath, max, starting)

    if storeResult.isOk():
      return true
    else:
      raise newException(ValueError, $storeResult.error)

  rpcServer.rpc("portal_" & network & "_offerContentInNodeRange") do(
      dbPath: string,
      nodeId: NodeId,
      max: uint32,
      starting: uint32) -> bool:
      # waiting for offer result, by the end of this call remote node should
      # have received offered content
      let offerResult = await p.offerContentInNodeRange(dbPath, nodeId, max, starting)

      if offerResult.isOk():
        return true
      else:
        raise newException(ValueError, $offerResult.error)
