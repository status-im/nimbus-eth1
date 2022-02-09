# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, sugar],
  stew/results, chronos,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./state_content,
  ./state_distance

const
  stateProtocolId* = [byte 0x50, 0x0A]

type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB

func setStreamTransport*(n: StateNetwork, transport: UtpDiscv5Protocol) =
  setTransport(n.portalProtocol.stream, transport)

proc toContentIdHandler(contentKey: ByteList): Option[ContentId] =
  toContentId(contentKey)

proc getContent*(n: StateNetwork, key: ContentKey):
    Future[Option[seq[byte]]] {.async.} =
  let
    keyEncoded = encode(key)
    contentId = toContentId(key)
    contentInRange = n.portalProtocol.inRange(contentId)

  # When the content id is in the radius range, try to look it up in the db.
  if contentInRange:
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      return contentFromDB

  let content = await n.portalProtocol.contentLookup(keyEncoded, contentId)

  # When content is found on the network and is in the radius range, store it.
  if content.isSome() and contentInRange:
    n.contentDB.put(contentId, content.get())

  # TODO: for now returning bytes, ultimately it would be nice to return proper
  # domain types.
  return content

proc new*(
    T: type StateNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    dataRadius = UInt256.high(),
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, stateProtocolId, contentDB, toContentIdHandler,
    dataRadius, bootstrapRecords, stateDistanceCalculator,
    config = portalConfig)

  return StateNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(n: StateNetwork) =
  n.portalProtocol.start()

proc stop*(n: StateNetwork) =
  n.portalProtocol.stop()
