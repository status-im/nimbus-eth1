# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, sugar],
  stew/[results, byteutils],
  eth/p2p/discoveryv5/[protocol, node, enr],
  ../../content_db,
  ../wire/portal_protocol,
  ./state_content,
  ./state_distance

const
  StateProtocolId* = "portal:state".toBytes()

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

proc getContent*(n: StateNetwork, key: ContentKey):
    Future[Option[seq[byte]]] {.async.} =
  let
    keyEncoded = encode(key)
    contentId = toContentId(keyEncoded)

  let nodeId = n.portalProtocol.localNode.id

  let distance = n.portalProtocol.routingTable.distance(nodeId, contentId)
  let inRange = distance <= n.portalProtocol.dataRadius

  # When the content id is in our radius range, try to look it up in our db.
  if inRange:
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      return contentFromDB

  let content = await n.portalProtocol.contentLookup(keyEncoded, contentId)

  if content.isSome() and inRange:
    n.contentDB.put(contentId, content.get().asSeq())

  # TODO: for now returning bytes, ultimately it would be nice to return proper
  # domain types.
  return content.map(x => x.asSeq())

proc new*(T: type StateNetwork, baseProtocol: protocol.Protocol,
    contentDB: ContentDB , dataRadius = UInt256.high(),
    bootstrapRecords: openarray[Record] = []): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, StateProtocolId, getHandler(contentDB), dataRadius,
    bootstrapRecords, stateDistanceCalculator)

  return StateNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(n: StateNetwork) =
  n.portalProtocol.start()

proc stop*(n: StateNetwork) =
  n.portalProtocol.stop()
