import
  std/[sequtils, sets, tables, options],
  stew/[results, byteutils], chronicles, chronos,
  eth/p2p/discoveryv5/[protocol, node, enr, routing_table],
  ../overlay/overlay_protocol,
  ./messages

logScope:
  topics = "content"

const
  ContentProtocolId* = "content".toBytes()

type
  SubProtocolId* = seq[byte]

  ContentHandler* = proc(contentKey: ContentKey): Option[Content] {.raises: [Defect], gcsafe.}

  ContentSubprotocol* = ref object
    baseProtocol*: protocol.Protocol
    overlaySubprotocol: OverlaySubProtocol
    handleContent: ContentHandler

  ContentProtocol* = ref object of TalkProtocol
    baseProtocol*: protocol.Protocol
    subProtocols: Table[SubProtocolId, ContentSubprotocol]

  ContentResult*[T] = Result[T, cstring]
  
proc handleFindContent(p: ContentSubprotocol, fc: FindContentMessage): seq[byte] =
  let maybeContent = p.handleContent(fc.contentKey)

  if maybeContent.isSome():
    let enrs = List[messages.ByteList, 32](@[]) # Empty enrs when payload is send
    encodeMessage(ContentMessage(
      subProtocolId: p.overlaySubprotocol.subProtocolIdAsList(),
      enrs: enrs, 
      payload: maybeContent.get()))
  else:
    let
      contentId = toContentId(fc.contentKey)
      # TODO it would be better to have separate function for neighbours, rather
      # than exposing routing table
      closestNodes = p.overlaySubprotocol.routingTable.neighbours(
        NodeId(readUintBE[256](contentId.data)), seenOnly = true)
      payload = messages.ByteList(@[]) # Empty payload when enrs are send
      enrs = closestNodes.map(proc(x: Node): messages.ByteList = messages.ByteList(x.record.raw))

    encodeMessage(ContentMessage(
      enrs: List[messages.ByteList, 32](List(enrs)), payload: payload))

proc findContent*(p: ContentSubprotocol, dst: Node, contentKey: ContentKey):
    Future[ContentResult[ContentMessage]] {.async.} =
  let fc = FindContentMessage(subProtocolId: p.overlaySubprotocol.subProtocolIdAsList(), contentKey: contentKey)

  trace "Send message request", dstId = dst.id, kind = MessageKind.findcontent

  let respResult = await talkreq(p.baseProtocol, dst, ContentProtocolId, encodeMessage(fc))

  return respResult
      .flatMap(proc (x: seq[byte]): Result[Message, cstring] = decodeMessage(x))
      .flatMap(proc (m: Message): ContentResult[ContentMessage] =
        if (m.kind == content):
          ok(m.content)
        else:
          err(cstring"Invalid message response received")
      )

# TODO here we assume that whoever uses conten protocol, will provide not started
# overlaySubprotocol, so start of content will equal to start of overlaySubprotocol
# this may be error prone.
proc start*(p: ContentSubprotocol) =
  p.overlaySubprotocol.start()

proc stop*(p: ContentSubprotocol) =
  p.overlaySubprotocol.stop()

proc messageHandler(protocol: TalkProtocol, request: seq[byte]): seq[byte] =
  doAssert(protocol of ContentProtocol)

  let p = ContentProtocol(protocol)

  let decoded = decodeMessage(request)
  if decoded.isOk():
    let message = decoded.get()
    trace "Received message response", kind = message.kind
    case message.kind
    of MessageKind.findcontent:
      let subProtocolId = message.findcontent.subProtocolId.asSeq()
      let subProtocol = p.subProtocols.getOrDefault(subProtocolId)
      if subProtocol.isNil():
        trace "Received message from not known protocol with id", id = subProtocolId
        @[]
      else:
        subProtocol.handleFindContent(message.findcontent)
    else:
      @[]
  else:
    @[]

proc new*(T: type ContentProtocol, baseProtocol: protocol.Protocol): T =
  let proto = ContentProtocol(
      protocolHandler: messageHandler,
      baseProtocol: baseProtocol
    )

  proto.baseProtocol.registerTalkProtocol(ContentProtocolId, proto).expect(
    "Only one protocol should have this id")

  proto

proc registerContentSubProtocol*(c: ContentProtocol, o: OverlaySubProtocol, handler: ContentHandler): ContentSubprotocol =
  let proto = ContentSubprotocol(baseProtocol: c.baseProtocol, overlaySubprotocol: o, handleContent: handler)
  c.subProtocols[o.subProtocolId] = proto
  proto
