# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
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

proc getContent(
    n: LightClientNetwork, contentKey: ContentKey):
    Future[results.Opt[seq[byte]]] {.async.} =
  let
    contentKeyEncoded = encode(contentKey)
    contentId = toContentId(contentKeyEncoded)
    localContent = n.portalProtocol.dbGet(contentKeyEncoded, contentId)

  if localContent.isSome():
    return localContent

  let contentRes = await n.portalProtocol.contentLookup(
      contentKeyEncoded, contentId)

  if contentRes.isNone():
    warn "Failed fetching content from the beacon chain network",
      contentKey = contentKeyEncoded
    return Opt.none(seq[byte])
  else:
    return Opt.some(contentRes.value().content)

proc getLightClientBootstrap*(
    n: LightClientNetwork,
    trustedRoot: Digest):
    Future[results.Opt[ForkedLightClientBootstrap]] {.async.} =
  let
    contentKey = bootstrapContentKey(trustedRoot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientBootstrap)

  let
    bootstrap = contentResult.value()
    decodingResult = decodeLightClientBootstrapForked(
      n.forkDigests, bootstrap)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientBootstrap)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.value())

proc getLightClientUpdatesByRange*(
    n: LightClientNetwork,
    startPeriod: SyncCommitteePeriod,
    count: uint64):
    Future[results.Opt[ForkedLightClientUpdateList]] {.async.} =
  let
    contentKey = updateContentKey(distinctBase(startPeriod), count)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientUpdateList)

  let
    updates = contentResult.value()
    decodingResult = decodeLightClientUpdatesByRange(
      n.forkDigests, updates)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientUpdateList)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.value())

proc getLightClientFinalityUpdate*(
    n: LightClientNetwork,
    finalizedSlot: uint64
  ): Future[results.Opt[ForkedLightClientFinalityUpdate]] {.async.} =
  let
    contentKey = finalityUpdateContentKey(finalizedSlot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientFinalityUpdate)

  let
    finalityUpdate = contentResult.value()
    decodingResult = decodeLightClientFinalityUpdateForked(
      n.forkDigests, finalityUpdate)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientFinalityUpdate)
  else:
    return Opt.some(decodingResult.value())

proc getLightClientOptimisticUpdate*(
    n: LightClientNetwork,
    optimisticSlot: uint64
  ): Future[results.Opt[ForkedLightClientOptimisticUpdate]] {.async.} =

  let
    contentKey = optimisticUpdateContentKey(optimisticSlot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientOptimisticUpdate)

  let
    optimisticUpdate = contentResult.value()
    decodingResult = decodeLightClientOptimisticUpdateForked(
      n.forkDigests, optimisticUpdate)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientOptimisticUpdate)
  else:
    return Opt.some(decodingResult.value())

proc new*(
    T: type LightClientNetwork,
    baseProtocol: protocol.Protocol,
    lightClientDb: LightClientDb,
    streamManager: StreamManager,
    forkDigests: ForkDigests,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let
    contentQueue = newAsyncQueue[(
      Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    # Need to adjust the radius to a static max value as for the Beacon chain
    # network all data must be accepted currently.
    portalConfigAdjusted = PortalProtocolConfig(
      tableIpLimits: portalConfig.tableIpLimits,
      bitsPerHop: portalConfig.bitsPerHop,
      radiusConfig: RadiusConfig(kind: Static, logRadius: 256),
      disablePoke: portalConfig.disablePoke)

    portalProtocol = PortalProtocol.new(
      baseProtocol, lightClientProtocolId,
      toContentIdHandler,
      createGetHandler(lightClientDb), stream, bootstrapRecords,
      config = portalConfigAdjusted)

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
      # They could be proven at moment of creation by checking finality update
      # its finalized_header. And verifying the current_sync_committee with the
      # header state root and current_sync_committee_branch?
      # Perhaps can be expanded to being able to verify back fill by storing
      # also the past beacon headers (This is sorta stored in a proof format
      # for history network also)
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
        asyncSpawn n.portalProtocol.randomGossipDiscardPeers(
          srcNodeId, contentKeys, contentItems
        )

  except CancelledError:
    trace "processContentLoop canceled"

proc start*(n: LightClientNetwork) =
  info "Starting portal beacon chain network"
  n.portalProtocol.start()
  n.processContentLoop = processContentLoop(n)

proc stop*(n: LightClientNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancelSoon()
