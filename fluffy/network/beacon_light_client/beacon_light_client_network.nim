# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[options, tables],
  stew/results, chronos, chronicles,
  eth/p2p/discoveryv5/[protocol, enr],
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/gossip_processing/light_client_processor,
  ../../../nimbus/constants,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/[beacon_light_client_content, beacon_light_client_db]

export beacon_light_client_content, beacon_light_client_db

logScope:
  topics = "portal_beacon_network"

const
  lightClientProtocolId* = [byte 0x50, 0x1A]

type
  LightClientNetwork* = ref object
    portalProtocol*: PortalProtocol
    lightClientDb*: LightClientDb
    processor*: ref LightClientProcessor
    contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
    forkDigests*: ForkDigests
    processContentLoop: Future[void]

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc getLightClientBootstrap*(
    n: LightClientNetwork,
    trustedRoot: Digest):
    Future[results.Opt[ForkedLightClientBootstrap]] {.async.} =
  let
    bk = LightClientBootstrapKey(blockHash: trustedRoot)
    ck = ContentKey(
      contentType: lightClientBootstrap,
      lightClientBootstrapKey: bk
    )
    keyEncoded = encode(ck)
    contentID = toContentId(keyEncoded)

  let bootstrapContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)

  if bootstrapContentLookup.isNone():
      warn "Failed fetching LightClientBootstrap from the network",
        trustedRoot, contentKey = keyEncoded
      return Opt.none(ForkedLightClientBootstrap)

  let
    bootstrap = bootstrapContentLookup.unsafeGet()
    decodingResult = decodeLightClientBootstrapForked(
      n.forkDigests, bootstrap.content)

  if decodingResult.isErr:
    return Opt.none(ForkedLightClientBootstrap)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.get())

proc getLightClientUpdatesByRange*(
    n: LightClientNetwork,
    startPeriod: SyncCommitteePeriod,
    count: uint64):
    Future[results.Opt[ForkedLightClientUpdateList]] {.async.} =
  let
    bk = LightClientUpdateKey(
      startPeriod: distinctBase(startPeriod), count: count)
    ck = ContentKey(
      contentType: lightClientUpdate,
      lightClientUpdateKey: bk
    )
    keyEncoded = encode(ck)
    contentID = toContentId(keyEncoded)

  let updatesResult =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)

  if updatesResult.isNone():
      warn "Failed fetching updates network", contentKey = keyEncoded
      return Opt.none(ForkedLightClientUpdateList)

  let
    updates = updatesResult.unsafeGet()
    decodingResult = decodeLightClientUpdatesByRange(
      n.forkDigests, updates.content)

  if decodingResult.isErr:
    return Opt.none(ForkedLightClientUpdateList)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.get())

proc getUpdate(
    n: LightClientNetwork, ck: ContentKey):
    Future[results.Opt[seq[byte]]] {.async.} =
  let
    keyEncoded = encode(ck)
    contentID = toContentId(keyEncoded)
    updateLookup = await n.portalProtocol.contentLookup(keyEncoded, contentId)

  if updateLookup.isNone():
    warn "Failed fetching update from the network", contentKey = keyEncoded
    return Opt.none(seq[byte])

  return ok(updateLookup.get().content)

# TODO:
# Currently both getLightClientFinalityUpdate and getLightClientOptimisticUpdate
# are implemented in naive way as finding first peer with any of those updates
# and treating it as latest. This will probably need to get improved.
proc getLightClientFinalityUpdate*(
    n: LightClientNetwork,
    currentFinalSlot: uint64,
    currentOptimisticSlot: uint64
  ): Future[results.Opt[ForkedLightClientFinalityUpdate]] {.async.} =

  let
    ck = finalityUpdateContentKey(currentFinalSlot, currentOptimisticSlot)
    lookupResult = await n.getUpdate(ck)

  if lookupResult.isErr:
    return Opt.none(ForkedLightClientFinalityUpdate)

  let
    finalityUpdate = lookupResult.get()
    decodingResult = decodeLightClientFinalityUpdateForked(
      n.forkDigests, finalityUpdate)

  if decodingResult.isErr:
    return Opt.none(ForkedLightClientFinalityUpdate)
  else:
    return Opt.some(decodingResult.get())

proc getLightClientOptimisticUpdate*(
    n: LightClientNetwork,
    currentOptimisticSlot: uint64
  ): Future[results.Opt[ForkedLightClientOptimisticUpdate]] {.async.} =

  let
    ck = optimisticUpdateContentKey(currentOptimisticSlot)
    lookupResult = await n.getUpdate(ck)

  if lookupResult.isErr:
    return Opt.none(ForkedLightClientOptimisticUpdate)

  let
    optimisticUpdate = lookupResult.get()
    decodingResult = decodeLightClientOptimisticUpdateForked(
      n.forkDigests, optimisticUpdate)

  if decodingResult.isErr:
    return Opt.none(ForkedLightClientOptimisticUpdate)
  else:
    return Opt.some(decodingResult.get())

proc new*(
    T: type LightClientNetwork,
    baseProtocol: protocol.Protocol,
    lightClientDb: LightClientDb,
    streamManager: StreamManager,
    forkDigests: ForkDigests,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let
    contentQueue = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    portalProtocol = PortalProtocol.new(
      baseProtocol, lightClientProtocolId,
      toContentIdHandler,
      createGetHandler(lightClientDb), stream, bootstrapRecords,
      config = portalConfig)

  portalProtocol.dbPut = createStoreHandler(lightClientDb)

  LightClientNetwork(
    portalProtocol: portalProtocol,
    lightClientDb: lightClientDb,
    contentQueue: contentQueue,
    forkDigests: forkDigests
  )

proc validateContent(
    n: LightClientNetwork, content: seq[byte], contentKey: ByteList):
    Future[bool] {.async.} =
  let key = contentKey.decode().valueOr:
    return false

  case key.contentType:
  of lightClientBootstrap:
    let decodingResult = decodeLightClientBootstrapForked(
      n.forkDigests, content)
    if decodingResult.isOk:
      # TODO:
      # Currently only verifying if the content can be decoded.
      # Later on we need to either provide a list of acceptable bootstraps (not
      # really scalable and requires quite some configuration) or find some
      # way to proof these.
      return true
    else:
      return false

  of lightClientUpdate:
    let decodingResult = decodeLightClientUpdatesByRange(
      n.forkDigests, content)
    if decodingResult.isOk:
      # TODO:
      # Currently only verifying if the content can be decoded.
      # Eventually only new updates that can be verified because the local
      # node is synced should be accepted.
      return true
    else:
      return false

  of lightClientFinalityUpdate:
    let decodingResult = decodeLightClientFinalityUpdateForked(
      n.forkDigests, content)
    if decodingResult.isOk:
      let res = n.processor[].processLightClientFinalityUpdate(
        MsgSource.gossip, decodingResult.get())
      if res.isErr():
        return false
      else:
        return true
    else:
      return false

  of lightClientOptimisticUpdate:
    let decodingResult = decodeLightClientOptimisticUpdateForked(
      n.forkDigests, content)
    if decodingResult.isOk:
      let res = n.processor[].processLightClientOptimisticUpdate(
        MsgSource.gossip, decodingResult.get())
      if res.isErr():
        return false
      else:
        return true
    else:
      return false

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
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    content: seq[seq[byte]]): Future[void] {.async.} =
  discard await p.neighborhoodGossip(srcNodeId, contentKeys, content)

proc processContentLoop(n: LightClientNetwork) {.async.} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentItems) =
        await n.contentQueue.popFirst()

      # When there is one invalid content item, all other content items are
      # dropped and not gossiped around.
      # TODO: Differentiate between failures due to invalid data and failures
      # due to missing network data for validation.
      if await n.validateContent(contentKeys, contentItems):
        asyncSpawn n.portalProtocol.neighborhoodGossipDiscardPeers(
          srcNodeId, contentKeys, contentItems
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
