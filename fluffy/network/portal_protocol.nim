# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/sequtils,
  stew/[results, byteutils], chronicles,
  eth/rlp, eth/p2p/discoveryv5/[protocol, node, enr],
  ../content,
  ./messages

export messages

logScope:
  topics = "portal"

const
  PortalProtocolId* = "portal".toBytes()

type
  PortalProtocol* = ref object of TalkProtocol
    baseProtocol*: protocol.Protocol
    dataRadius*: UInt256
    contentStorage*: ContentStorage

proc handlePing(p: PortalProtocol, ping: PingMessage):
    seq[byte] =
  let p = PongMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    dataRadius: p.dataRadius)

  encodeMessage(p)

proc handleFindNode(p: PortalProtocol, fn: FindNodeMessage): seq[byte] =
  if fn.distances.len == 0:
    let enrs = List[ByteList, 32](@[])
    encodeMessage(NodesMessage(total: 1, enrs: enrs))
  elif fn.distances.contains(0):
    # A request for our own record.
    let enr = ByteList(rlp.encode(p.baseProtocol.localNode.record))
    encodeMessage(NodesMessage(total: 1, enrs: List[ByteList, 32](@[enr])))
  else:
    let distances = fn.distances.asSeq()
    if distances.all(proc (x: uint16): bool = return x <= 256):
      let
        nodes = p.baseProtocol.neighboursAtDistances(distances, seenOnly = true)
        enrs = nodes.map(proc(x: Node): ByteList = ByteList(x.record.raw))

      # TODO: Fixed here to total message of 1 for now, as else we would need to
      # either move the send of the talkresp messages here, or allow for
      # returning multiple messages.
      # On the long run, it might just be better to use a stream in these cases?
      encodeMessage(
        NodesMessage(total: 1, enrs: List[ByteList, 32](List(enrs))))
    else:
      # invalid request, send empty back
      let enrs = List[ByteList, 32](@[])
      encodeMessage(NodesMessage(total: 1, enrs: enrs))

proc handleFindContent(p: PortalProtocol, fc: FindContentMessage): seq[byte] =
  # TODO: Need to check networkId, type, trie path
  let
    # TODO: Should we first do a simple check on ContentId versus Radius?
    contentId = toContentId(fc.contentKey)
    content = p.contentStorage.getContent(fc.contentKey)
  if content.isSome():
    let enrs = List[ByteList, 32](@[]) # Empty enrs when payload is send
    encodeMessage(FoundContentMessage(
      enrs: enrs, payload: ByteList(content.get())))
  else:
    let
      closestNodes = p.baseProtocol.neighbours(
        NodeId(readUintBE[256](contentId.data)), seenOnly = true)
      payload = ByteList(@[]) # Empty payload when enrs are send
      enrs =
        closestNodes.map(proc(x: Node): ByteList = ByteList(x.record.raw))

    encodeMessage(FoundContentMessage(
      enrs: List[ByteList, 32](List(enrs)), payload: payload))

proc handleAdvertise(p: PortalProtocol, a: AdvertiseMessage): seq[byte] =
  # TODO: Not implemented
  let
    connectionId = List[byte, 4](@[])
    contentKeys = List[ByteList, 32](@[])
  encodeMessage(RequestProofsMessage(connectionId: connectionId,
    contentKeys: contentKeys))

proc messageHandler*(protocol: TalkProtocol, request: seq[byte]): seq[byte] =
  doAssert(protocol of PortalProtocol)

  let p = PortalProtocol(protocol)

  let decoded = decodeMessage(request)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message response", kind = message.kind
    case message.kind
    of MessageKind.ping:
      p.handlePing(message.ping)
    of MessageKind.findnode:
      p.handleFindNode(message.findNode)
    of MessageKind.findcontent:
      p.handleFindContent(message.findcontent)
    of MessageKind.advertise:
      p.handleAdvertise(message.advertise)
    else:
      @[]
  else:
    @[]

proc new*(T: type PortalProtocol, baseProtocol: protocol.Protocol,
    dataRadius = UInt256.high()): T =
  let proto = PortalProtocol(
    protocolHandler: messageHandler,
    baseProtocol: baseProtocol,
    dataRadius: dataRadius)

  proto.baseProtocol.registerTalkProtocol(PortalProtocolId, proto).expect(
    "Only one protocol should have this id")

  return proto

proc ping*(p: PortalProtocol, dst: Node):
    Future[DiscResult[PongMessage]] {.async.} =
  let ping = PingMessage(enrSeq: p.baseProtocol.localNode.record.seqNum,
    dataRadius: p.dataRadius)

  # TODO: This send and response handling code could be more generalized for the
  # different message types.
  trace "Send message request", dstId = dst.id, kind = MessageKind.ping
  let talkresp = await talkreq(p.baseProtocol, dst, PortalProtocolId,
    encodeMessage(ping))

  if talkresp.isOk():
    let decoded = decodeMessage(talkresp.get().response)
    if decoded.isOk():
      let message = decoded.get()
      if message.kind == pong:
        return ok(message.pong)
      else:
        return err("Invalid message response received")
    else:
      return err(decoded.error)
  else:
    return err(talkresp.error)

proc findNode*(p: PortalProtocol, dst: Node, distances: List[uint16, 256]):
    Future[DiscResult[NodesMessage]] {.async.} =
  let fn = FindNodeMessage(distances: distances)

  trace "Send message request", dstId = dst.id, kind = MessageKind.findnode
  let talkresp = await talkreq(p.baseProtocol, dst, PortalProtocolId,
    encodeMessage(fn))

  if talkresp.isOk():
    let decoded = decodeMessage(talkresp.get().response)
    if decoded.isOk():
      let message = decoded.get()
      if message.kind == nodes:
        # TODO: Verify nodes here
        return ok(message.nodes)
      else:
        return err("Invalid message response received")
    else:
      return err(decoded.error)
  else:
    return err(talkresp.error)

proc findContent*(p: PortalProtocol, dst: Node, contentKey: ContentKey):
    Future[DiscResult[FoundContentMessage]] {.async.} =
  let fc = FindContentMessage(contentKey: contentKey)

  trace "Send message request", dstId = dst.id, kind = MessageKind.findcontent
  let talkresp = await talkreq(p.baseProtocol, dst, PortalProtocolId,
    encodeMessage(fc))

  if talkresp.isOk():
    let decoded = decodeMessage(talkresp.get().response)
    if decoded.isOk():
      let message = decoded.get()
      if message.kind == foundcontent:
        return ok(message.foundcontent)
      else:
        return err("Invalid message response received")
    else:
      return err(decoded.error)
  else:
    return err(talkresp.error)
