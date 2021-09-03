import
  std/[options, sugar],
  stew/results,
  eth/p2p/discoveryv5/[protocol, node],
  ./content, ./portal_protocol

# TODO expose function in domain specific way i.e operating od state network objects i.e
# nodes, tries, hashes
type PortalNetwork* = ref object
  storage: ContentStorage
  portalProtocol*: PortalProtocol

proc getHandler(storage: ContentStorage): ContentHandler =
  result =
    proc (contentKey: content.ByteList): ContentResult =
      let maybeContent = storage.getContent(contentKey)
      if (maybeContent.isSome()):
        ContentResult(kind: ContentFound, content: maybeContent.unsafeGet())
      else:
        ContentResult(kind: ContentMissing, contentId: toContentId(contentKey))

# Further improvements which may be necessary:
# 1. Return proper domain types instead of bytes
# 2. First check if item is in storage instead of doing lookup
# 3. Put item into storage (if in radius) after succesful lookup
proc getContent*(p:PortalNetwork, key: ContentKey): Future[Option[seq[byte]]] {.async.} = 
  let keyAsBytes = encodeKeyAsList(key)
  let id = contentIdAsUint256(toContentId(keyAsBytes))
  let result = await p.portalProtocol.contentLookup(keyAsBytes, id)
  # for now returning bytes, ultimatly it would be nice to return proper domain types from here
  return result.map(x => x.asSeq())

proc new*(T: type PortalNetwork, baseProtocol: protocol.Protocol, storage: ContentStorage , dataRadius = UInt256.high()): T =
  let portalProto = PortalProtocol.new(baseProtocol, getHandler(storage), dataRadius)
  return PortalNetwork(storage: storage, portalProtocol: portalProto)

proc start*(p: PortalNetwork) =
  p.portalProtocol.start()

proc stop*(p: PortalNetwork) =
  p.portalProtocol.stop()

