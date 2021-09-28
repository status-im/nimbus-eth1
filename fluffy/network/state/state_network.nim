import
  std/[options, sugar],
  stew/[results, byteutils],
  eth/p2p/discoveryv5/[protocol, node, enr],
  ../../content_db,
  ../wire/portal_protocol,
  ./state_content

const
  StateProtocolId* = "portal:state".toBytes()

# TODO expose function in domain specific way i.e operating od state network
# objects i.e nodes, tries, hashes
type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB

proc getHandler(contentDB: ContentDB): ContentHandler =
    return (proc (contentKey: state_content.ByteList): ContentResult =
      let contentId = toContentId(contentKey)
      let maybeContent = contentDB.get(contentId)
      if (maybeContent.isSome()):
        ContentResult(kind: ContentFound, content: maybeContent.unsafeGet())
      else:
        ContentResult(kind: ContentMissing, contentId: contentId))

# Further improvements which may be necessary:
# 1. Return proper domain types instead of bytes
# 2. First check if item is in storage instead of doing lookup
# 3. Put item into storage (if in radius) after succesful lookup
proc getContent*(p: StateNetwork, key: ContentKey):
    Future[Option[seq[byte]]] {.async.} =
  let
    keyEncoded = encode(key)
    id = toContentId(keyEncoded)
    content = await p.portalProtocol.contentLookup(keyEncoded, id)
  # for now returning bytes, ultimately it would be nice to return proper domain
  # types from here
  return content.map(x => x.asSeq())

proc new*(T: type StateNetwork, baseProtocol: protocol.Protocol,
    contentDB: ContentDB , dataRadius = UInt256.high(),
    bootstrapRecords: openarray[Record] = []): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, StateProtocolId, getHandler(contentDB), dataRadius,
    bootstrapRecords)

  return StateNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(p: StateNetwork) =
  p.portalProtocol.start()

proc stop*(p: StateNetwork) =
  p.portalProtocol.stop()
