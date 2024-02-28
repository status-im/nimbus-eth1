# fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/results,
  chronos,
  chronicles,
  eth/p2p/discoveryv5/[protocol, enr],
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/gossip_processing/light_client_processor,
  ../../../nimbus/constants,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/[beacon_content, beacon_db, beacon_chain_historical_summaries]

export beacon_content, beacon_db

logScope:
  topics = "beacon_network"

const lightClientProtocolId* = [byte 0x50, 0x1A]

type BeaconNetwork* = ref object
  portalProtocol*: PortalProtocol
  beaconDb*: BeaconDb
  processor*: ref LightClientProcessor
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  forkDigests*: ForkDigests
  processContentLoop: Future[void]

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc validateHistoricalSummaries(
    n: BeaconNetwork, summariesWithProof: HistoricalSummariesWithProof
): Result[void, string] =
  let
    finalityUpdate = getLastFinalityUpdate(n.beaconDb).valueOr:
      return err("Require finality update for verification")

    # TODO: compare slots first
    stateRoot = withForkyFinalityUpdate(finalityUpdate):
      when lcDataFork > LightClientDataFork.None:
        forkyFinalityUpdate.finalized_header.beacon.state_root
      else:
        # Note: this should always be the case as historical_summaries was
        # introduced in Capella.
        return err("Require Altair or > for verification")

  if summariesWithProof.verifyProof(stateRoot):
    ok()
  else:
    err("Failed verifying historical_summaries proof")

proc getContent(
    n: BeaconNetwork, contentKey: ContentKey
): Future[results.Opt[seq[byte]]] {.async.} =
  let
    contentKeyEncoded = encode(contentKey)
    contentId = toContentId(contentKeyEncoded)
    localContent = n.portalProtocol.dbGet(contentKeyEncoded, contentId)

  if localContent.isSome():
    return localContent

  let contentRes = await n.portalProtocol.contentLookup(contentKeyEncoded, contentId)

  if contentRes.isNone():
    warn "Failed fetching content from the beacon chain network",
      contentKey = contentKeyEncoded
    return Opt.none(seq[byte])
  else:
    return Opt.some(contentRes.value().content)

proc getLightClientBootstrap*(
    n: BeaconNetwork, trustedRoot: Digest
): Future[results.Opt[ForkedLightClientBootstrap]] {.async.} =
  let
    contentKey = bootstrapContentKey(trustedRoot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientBootstrap)

  let
    bootstrap = contentResult.value()
    decodingResult = decodeLightClientBootstrapForked(n.forkDigests, bootstrap)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientBootstrap)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.value())

proc getLightClientUpdatesByRange*(
    n: BeaconNetwork, startPeriod: SyncCommitteePeriod, count: uint64
): Future[results.Opt[ForkedLightClientUpdateList]] {.async.} =
  let
    contentKey = updateContentKey(distinctBase(startPeriod), count)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientUpdateList)

  let
    updates = contentResult.value()
    decodingResult = decodeLightClientUpdatesByRange(n.forkDigests, updates)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientUpdateList)
  else:
    # TODO Not doing validation for now, as probably it should be done by layer
    # above
    return Opt.some(decodingResult.value())

proc getLightClientFinalityUpdate*(
    n: BeaconNetwork, finalizedSlot: uint64
): Future[results.Opt[ForkedLightClientFinalityUpdate]] {.async.} =
  let
    contentKey = finalityUpdateContentKey(finalizedSlot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientFinalityUpdate)

  let
    finalityUpdate = contentResult.value()
    decodingResult =
      decodeLightClientFinalityUpdateForked(n.forkDigests, finalityUpdate)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientFinalityUpdate)
  else:
    return Opt.some(decodingResult.value())

proc getLightClientOptimisticUpdate*(
    n: BeaconNetwork, optimisticSlot: uint64
): Future[results.Opt[ForkedLightClientOptimisticUpdate]] {.async.} =
  let
    contentKey = optimisticUpdateContentKey(optimisticSlot)
    contentResult = await n.getContent(contentKey)

  if contentResult.isNone():
    return Opt.none(ForkedLightClientOptimisticUpdate)

  let
    optimisticUpdate = contentResult.value()
    decodingResult =
      decodeLightClientOptimisticUpdateForked(n.forkDigests, optimisticUpdate)

  if decodingResult.isErr():
    return Opt.none(ForkedLightClientOptimisticUpdate)
  else:
    return Opt.some(decodingResult.value())

proc getHistoricalSummaries*(
    n: BeaconNetwork
): Future[results.Opt[HistoricalSummaries]] {.async.} =
  # Note: when taken from the db, it does not need to verify the proof.
  let
    contentKey = historicalSummariesContentKey()
    content = ?await n.getContent(contentKey)

    summariesWithProof = decodeSsz(content, HistoricalSummariesWithProof).valueOr:
      return Opt.none(HistoricalSummaries)

  if n.validateHistoricalSummaries(summariesWithProof).isOk():
    return Opt.some(summariesWithProof.historical_summaries)
  else:
    return Opt.none(HistoricalSummaries)

proc new*(
    T: type BeaconNetwork,
    baseProtocol: protocol.Protocol,
    beaconDb: BeaconDb,
    streamManager: StreamManager,
    forkDigests: ForkDigests,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
): T =
  let
    contentQueue = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    # Need to adjust the radius to a static max value as for the Beacon chain
    # network all data must be accepted currently.
    portalConfigAdjusted = PortalProtocolConfig(
      tableIpLimits: portalConfig.tableIpLimits,
      bitsPerHop: portalConfig.bitsPerHop,
      radiusConfig: RadiusConfig(kind: Static, logRadius: 256),
      disablePoke: portalConfig.disablePoke,
    )

    portalProtocol = PortalProtocol.new(
      baseProtocol,
      lightClientProtocolId,
      toContentIdHandler,
      createGetHandler(beaconDb),
      stream,
      bootstrapRecords,
      config = portalConfigAdjusted,
    )

  portalProtocol.dbPut = createStoreHandler(beaconDb)

  BeaconNetwork(
    portalProtocol: portalProtocol,
    beaconDb: beaconDb,
    contentQueue: contentQueue,
    forkDigests: forkDigests,
  )

proc validateContent(
    n: BeaconNetwork, content: seq[byte], contentKey: ByteList
): Result[void, string] =
  let key = contentKey.decode().valueOr:
    return err("Error decoding content key")

  case key.contentType
  of unused:
    raiseAssert "Should not be used and fail at decoding"
  of lightClientBootstrap:
    let decodingResult = decodeLightClientBootstrapForked(n.forkDigests, content)
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
      ok()
    else:
      err("Error decoding content: " & decodingResult.error)
  of lightClientUpdate:
    let decodingResult = decodeLightClientUpdatesByRange(n.forkDigests, content)
    if decodingResult.isOk:
      # TODO:
      # Currently only verifying if the content can be decoded.
      # Eventually only new updates that can be verified because the local
      # node is synced should be accepted.
      ok()
    else:
      err("Error decoding content: " & decodingResult.error)
  of lightClientFinalityUpdate:
    let update = decodeLightClientFinalityUpdateForked(n.forkDigests, content).valueOr:
      return err("Error decoding content: " & error)

    let res = n.processor[].processLightClientFinalityUpdate(MsgSource.gossip, update)
    if res.isErr():
      err("Error processing update: " & $res.error[1])
    else:
      ok()
  of lightClientOptimisticUpdate:
    let update = decodeLightClientOptimisticUpdateForked(n.forkDigests, content).valueOr:
      return err("Error decoding content: " & error)

    let res = n.processor[].processLightClientOptimisticUpdate(MsgSource.gossip, update)
    if res.isErr():
      err("Error processing update: " & $res.error[1])
    else:
      ok()
  of beacon_content.ContentType.historicalSummaries:
    let summariesWithProof = ?decodeSsz(content, HistoricalSummariesWithProof)

    n.validateHistoricalSummaries(summariesWithProof)

proc validateContent(
    n: BeaconNetwork, contentKeys: ContentKeysList, contentItems: seq[seq[byte]]
): Future[bool] {.async.} =
  # content passed here can have less items then contentKeys, but not more.
  for i, contentItem in contentItems:
    let
      contentKey = contentKeys[i]
      validation = n.validateContent(contentItem, contentKey)
    if validation.isOk():
      let contentIdOpt = n.portalProtocol.toContentId(contentKey)
      if contentIdOpt.isNone():
        error "Received offered content with invalid content key", contentKey
        return false

      let contentId = contentIdOpt.get()
      n.portalProtocol.storeContent(contentKey, contentId, contentItem)

      info "Received offered content validated successfully", contentKey
    else:
      error "Received offered content failed validation",
        contentKey, error = validation.error
      return false

  return true

proc processContentLoop(n: BeaconNetwork) {.async.} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentItems) = await n.contentQueue.popFirst()

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

proc start*(n: BeaconNetwork) =
  info "Starting portal beacon chain network"
  n.portalProtocol.start()
  n.processContentLoop = processContentLoop(n)

proc stop*(n: BeaconNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancelSoon()
