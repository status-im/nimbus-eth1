import
  std/[options, sugar],
  stew/[results, byteutils],
  eth/p2p/discoveryv5/[protocol, node, enr],
  ../wire/portal_protocol,
  ./state_content

const
  StateProtocolId* = "portal:state".toBytes()

# TODO expose function in domain specific way i.e operating od state network
# objects i.e nodes, tries, hashes
type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  storage: ContentStorage

proc getHandler(storage: ContentStorage): ContentHandler =
    return (proc (contentKey: state_content.ByteList): ContentResult =
      let maybeContent = storage.getContent(contentKey)
      if (maybeContent.isSome()):
        ContentResult(kind: ContentFound, content: maybeContent.unsafeGet())
      else:
        ContentResult(kind: ContentMissing, contentId: toContentId(contentKey)))

# Further improvements which may be necessary:
# 1. Return proper domain types instead of bytes
# 2. First check if item is in storage instead of doing lookup
# 3. Put item into storage (if in radius) after succesful lookup
proc getContent*(p: StateNetwork, key: ContentKey):
    Future[Option[seq[byte]]] {.async.} =
  let keyAsBytes = encodeKeyAsList(key)
  let id = contentIdAsUint256(toContentId(keyAsBytes))
  let result = await p.portalProtocol.contentLookup(keyAsBytes, id)
  # for now returning bytes, ultimatly it would be nice to return proper domain
  # types from here
  return result.map(x => x.asSeq())

proc new*(T: type StateNetwork, baseProtocol: protocol.Protocol,
    storage: ContentStorage , dataRadius = UInt256.high(),
    bootstrapRecords: openarray[Record] = []): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, StateProtocolId, getHandler(storage), dataRadius,
    bootstrapRecords)

  return StateNetwork(portalProtocol: portalProtocol, storage: storage)

proc start*(p: StateNetwork) =
  p.portalProtocol.start()

proc stop*(p: StateNetwork) =
  p.portalProtocol.stop()
