import
  std/options,
  stew/results,
  eth/p2p/discoveryv5/[protocol, node],
  ./messages, ./content, ./portal_protocol

# TODO expose function in domain specific way i.e operating od state network objects i.e
# nodes, tries, hashes
type PortalNetwork* = ref object
  storage: ContentStorage
  proto*: PortalProtocol

proc getHandler(storage: ContentStorage): ContentHandler =
  result =
    proc (contentKey: ByteList): ContentResult =
      let maybeContent = storage.getContent(contentKey)
      if (maybeContent.isSome()):
        ContentResult(kind: ContentFound, content: maybeContent.unsafeGet())
      else:
        ContentResult(kind: ContentMissing, contentId: toContentId(contentKey))

# TODO temporary find content exposing Node, ulimatly this function would use
# contentLookup, so uper layer would not need to know anything about
# routing table nodes
proc findContent*(p:PortalNetwork, key: ContentKey, dst: Node): Future[Option[seq[byte]]] {.async.} = 
  var maybeContent: Option[seq[byte]] = none[seq[byte]]()
  let keyAsBytes = encodeKeyAsList(key)
  let fcResponse = await p.proto.findcontent(dst, keyAsBytes)

  if (fcResponse.isOk()):
    let message = fcResponse.get()
    if (len(message.payload) > 0):
      maybeContent = some(message.payload.asSeq())

  return maybeContent

proc new*(T: type PortalNetwork, baseProtocol: protocol.Protocol, storage: ContentStorage , dataRadius = UInt256.high()): T =
  let portalProto = PortalProtocol.new(baseProtocol, getHandler(storage), dataRadius)
  return PortalNetwork(storage: storage, proto: portalProto)

proc start*(p: PortalNetwork) =
  p.proto.start()

proc stop*(p: PortalNetwork) =
  p.proto.stop()

