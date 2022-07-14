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
      dbName: string,
      max: uint32,
      starting: uint32) -> bool:

    let
      localRadius = p.dataRadius
      db = SeedDb.new(path = dbPath, name = dbName)
      localId = p.localNode.id
      contentInRange = db.getContentInRange(localId, localRadius, int64(max), int64(starting))

    db.close()

    for contentData in contentInRange:
      let cid = UInt256.fromBytesBE(contentData.contentId)
      p.storeContent(cid, contentData.content)

    return true

  rpcServer.rpc("portal_" & network & "_offerContentInNodeRange") do(
      dbPath: string,
      dbName: string,
      nodeId: NodeId,
      max: uint32,
      starting: uint32) -> bool:
      ## Offers `max` closest elements starting from `starting` index to peer
      ## with given `nodeId`.
      ## Maxium value of `max` is 64 , as this is limit for single offer.
      ## `starting` argument is needed as seed_db is read only, so if there is
      ## more content in peer range than max, then to offer 64 closest elements
      # it needs to be set to 0. To offer next 64 elements it need to be set to
      # 64 etc.
      let maybeNodeAndRadius = await p.resolveWithRadius(nodeId)

      if maybeNodeAndRadius.isNone():
         raise newException(ValueError, "Could not find node with provided nodeId")

      let
        db = SeedDb.new(path = dbPath, name = dbName)
        (node, radius) = maybeNodeAndRadius.unsafeGet()
        content = db.getContentInRange(node.id, radius, int64(max), int64(starting))

      # We got all we wanted from seed_db, it can be closed now.
      db.close()

      var ci: seq[ContentInfo]

      for cont in content:
        let k = ByteList.init(cont.contentKey)
        let info = ContentInfo(contentKey: k, content: cont.content)
        ci.add(info)

      # waiting for offer result, by the end of this call remote node should
      # have received offered content
      let offerResult = await p.offer(node, ci)

      if offerResult.isOk():
        return true
      else:
        raise newException(ValueError, $offerResult.error)
