# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, tables],
  stew/results, chronos, chronicles,
  eth/p2p/discoveryv5/[protocol, enr],
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  ../../content_db,
  ../../../nimbus/constants,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/light_client_content

logScope:
  topics = "portal_lc"

const
  lightClientProtocolId* = [byte 0x50, 0x1A]

type
  LightClientNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(ContentKeysList, seq[seq[byte]])]
    forkDigests*: ForkDigests
    processContentLoop: Future[void]

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

func encodeKey(k: ContentKey): (ByteList, ContentId) =
  let keyEncoded = encode(k)
  return (keyEncoded, toContentId(keyEncoded))

proc dbGetHandler(db: ContentDB, contentId: ContentId):
    Option[seq[byte]] {.raises: [Defect], gcsafe.} =
  db.get(contentId)

proc getLightClientBootstrap*(
    l: LightClientNetwork,
    trustedRoot: Digest): Future[results.Opt[altair.LightClientBootstrap]] {.async.} =
  let
    bk = LightClientBootstrapKey(blockHash: trustedRoot)
    ck = ContentKey(
      contentType: lightClientbootstrap,
      lightClientBootstrapKey: bk
    )
    keyEncoded = encode(ck)
    contentID = toContentId(keyEncoded)

  let bootstrapContentLookup =
      await l.portalProtocol.contentLookup(keyEncoded, contentId)

  if bootstrapContentLookup.isNone():
      warn "Failed fetching block header from the network", trustedRoot, contentKey = keyEncoded
      return Opt.none(altair.LightClientBootstrap)

  let
    bootstrap = bootstrapContentLookup.unsafeGet()
    decodingResult = decodeBootstrapForked(l.forkDigests, bootstrap.content)

  if decodingResult.isErr:
    return Opt.none(altair.LightClientBootstrap)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.get())

proc getLightClientUpdatesByRange*(
    l: LightClientNetwork,
    startPeriod: uint64,
    count: uint64): Future[results.Opt[seq[altair.LightClientUpdate]]] {.async.} =
  # TODO: Not implemented!
  return Opt.none(seq[altair.LightClientUpdate])

proc getLatestUpdate( l: LightClientNetwork, optimistic: bool):Future[results.Opt[seq[byte]]] {.async.} =
  let ck =
    if optimistic:
      ContentKey(
        contentType: lightClientOptimisticUpdate,
        lightClientOptimisticUpdateKey: LightClientOptimisticUpdateKey()
      )
    else:
      ContentKey(
        contentType: lightClientFinalityUpdate,
        lightClientFinalityUpdateKey: LightClientFinalityUpdateKey()
      )

  let
    keyEncoded = encode(ck)
    contentID = toContentId(keyEncoded)
    updateLooukup = await l.portalProtocol.contentLookup(keyEncoded, contentId)

  if updateLooukup.isNone():
    warn "Failed fetching update from the network", contentKey = keyEncoded
    return Opt.none(seq[byte])

  return ok(updateLooukup.get().content)

# TODO: Currently both getLightClientFinalityUpdate and getLightClientOptimisticUpdate
# are implemented in naive way as finding first peer with any of those updates
# and treating it as latest. This will probably need to get improved.
proc getLightClientFinalityUpdate*(
    l: LightClientNetwork
  ): Future[results.Opt[altair.LightClientFinalityUpdate]] {.async.} =
  let lookupResult = await l.getLatestUpdate(optimistic = false)

  if lookupResult.isErr:
    return Opt.none(altair.LightClientFinalityUpdate)

  let
    finalityUpdate = lookupResult.get()
    decodingResult = decodeLightClientFinalityUpdateForked(l.forkDigests, finalityUpdate)

  if decodingResult.isErr:
    return Opt.none(altair.LightClientFinalityUpdate)
  else:
    return Opt.some(decodingResult.get())

proc getLightClientOptimisticUpdate*(
    l: LightClientNetwork
  ): Future[results.Opt[altair.LightClientOptimisticUpdate]] {.async.} =

  let lookupResult = await l.getLatestUpdate(optimistic = true)

  if lookupResult.isErr:
    return Opt.none(altair.LightClientOptimisticUpdate)

  let
    optimimsticUpdate = lookupResult.get()
    decodingResult = decodeLightClientOptimisticUpdateForked(l.forkDigests, optimimsticUpdate)

  if decodingResult.isErr:
    return Opt.none(altair.LightClientOptimisticUpdate)
  else:
    return Opt.some(decodingResult.get())

proc new*(
    T: type LightClientNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    forkDigests: ForkDigests,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let
    contentQueue = newAsyncQueue[(ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    portalProtocol = PortalProtocol.new(
      baseProtocol, lightClientProtocolId,
      toContentIdHandler, createGetHandler(contentDB), stream, bootstrapRecords,
      config = portalConfig)

  portalProtocol.dbPut = createStoreHandler(contentDB, portalConfig.radiusConfig, portalProtocol)

  LightClientNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: contentQueue,
    forkDigests: forkDigests
  )

# TODO this should be probably supplied by upper layer i.e Light client which uses
# light client network as data provider as only it has all necessary context to
# validate data
proc validateContent(
    n: LightClientNetwork, content: seq[byte], contentKey: ByteList):
    Future[bool] {.async.} =
  return true

proc validateContent(
    n: LightClientNetwork,
    contentKeys: ContentKeysList,
    contentItems: seq[seq[byte]]): Future[bool] {.async.} =
  # content passed here can have less items then contentKeys, but not more.
  for i, contentItem in contentItems:
    let contentKey = contentKeys[i]
    if await n.validateContent(contentItem, contentKey):
      let contentIdOpt = n.portalProtocol.toContentId(contentKey)
      if contentIdOpt.isNone():
        error "Received offered content with invalid content key", contentKey
        return false

      let contentId = contentIdOpt.get()

      n.portalProtocol.storeContent(contentKey, contentId, contentItem)

      info "Received offered content validated successfully", contentKey

    else:
      error "Received offered content failed validation", contentKey
      return false

  return true

proc neighborhoodGossipDiscardPeers(
    p: PortalProtocol,
    contentKeys: ContentKeysList,
    content: seq[seq[byte]]): Future[void] {.async.} =
  discard await p.neighborhoodGossip(contentKeys, content)

proc processContentLoop(n: LightClientNetwork) {.async.} =
  try:
    while true:
      let (contentKeys, contentItems) =
        await n.contentQueue.popFirst()

      # When there is one invalid content item, all other content items are
      # dropped and not gossiped around.
      # TODO: Differentiate between failures due to invalid data and failures
      # due to missing network data for validation.
      if await n.validateContent(contentKeys, contentItems):
        asyncSpawn n.portalProtocol.neighborhoodGossipDiscardPeers(
          contentKeys, contentItems
        )

  except CancelledError:
    trace "processContentLoop canceled"

proc start*(n: LightClientNetwork) =
  info "Starting portal light client network"
  n.portalProtocol.start()
  n.processContentLoop = processContentLoop(n)

proc stop*(n: LightClientNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancel()
