# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/options,
  stew/results, chronos, chronicles,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./state_content,
  ./state_distance

logScope:
  topics = "portal_state"

const
  stateProtocolId* = [byte 0x50, 0x0A]

type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB
  processContentLoop: Future[void]

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

  if content.isNone():
    return none[seq[byte]]()

  let contentResult = content.get()

  # When content is found on the network and is in the radius range, store it.
  if content.isSome() and contentInRange:
    # TODO Add poke when working on state network
    # TODO When working on state network, make it possible to pass different
    # distance functions to store content
    n.portalProtocol.storeContent(contentId, contentResult.content)

  # TODO: for now returning bytes, ultimately it would be nice to return proper
  # domain types.
  return some(contentResult.content)

proc validateContent(content: openArray[byte], contentKey: ByteList): bool =
  true

proc new*(
    T: type StateNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, stateProtocolId, contentDB,
    toContentIdHandler,
    bootstrapRecords, stateDistanceCalculator,
    config = portalConfig)

  return StateNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc processContentLoop(n: StateNetwork) {.async.} =
  try:
    while true:
      # Just dropping state date for now
      discard await n.portalProtocol.stream.contentQueue.popFirst()
  except CancelledError:
    trace "processContentLoop canceled"

proc start*(n: StateNetwork) =
  info "Starting Portal execution state network",
    protocolId = n.portalProtocol.protocolId
  n.portalProtocol.start()

  n.processContentLoop = processContentLoop(n)

proc stop*(n: StateNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancel()
