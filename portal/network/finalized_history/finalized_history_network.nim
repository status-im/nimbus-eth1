# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  metrics,
  eth/common/headers,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../common/common_types,
  ../../database/content_db,
  # ../network_metadata,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config, ping_extensions],
  "."/[finalized_history_content, finalized_history_validation]

from eth/common/accounts import EMPTY_ROOT_HASH

logScope:
  topics = "portal_fin_hist"

const pingExtensionCapabilities = {CapabilitiesType, HistoryRadiusType}

type FinalizedHistoryNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  # cfg*: RuntimeConfig
  processContentLoops: seq[Future[void]]
  statusLogLoop: Future[void]
  contentRequestRetries: int
  contentQueueWorkers: int

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  toContentId(contentKey)

proc new*(
    T: type FinalizedHistoryNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    # cfg: RuntimeConfig,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
    contentRequestRetries = 1,
    contentQueueWorkers = 50,
    contentQueueSize = 50,
): T =
  let
    contentQueue =
      newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](contentQueueSize)

    stream = streamManager.registerNewStream(contentQueue)

    portalProtocol = PortalProtocol.new(
      baseProtocol,
      [byte(0x50), 0x00], # TODO: Adapt getProtocolId
      toContentIdHandler,
      createGetHandler(contentDB),
      createStoreHandler(contentDB, portalConfig.radiusConfig),
      createContainsHandler(contentDB),
      createRadiusHandler(contentDB),
      stream,
      bootstrapRecords,
      config = portalConfig,
      pingExtensionCapabilities = pingExtensionCapabilities,
    )

  FinalizedHistoryNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: contentQueue,
    # cfg: cfg,
    contentRequestRetries: contentRequestRetries,
    contentQueueWorkers: contentQueueWorkers,
  )

proc validateContent(
    n: FinalizedHistoryNetwork, content: seq[byte], contentKeyBytes: ContentKeyByteList
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  # TODO: specs might turn out to just disable offers. Although I think for for getting initial data in the network
  # this might be an issue. Unless history expiry gets deployed together with Portal.
  let contentKey = finalized_history_content.decode(contentKeyBytes).valueOr:
    return err("Error decoding content key")

  case contentKey.contentType
  of unused:
    raiseAssert("ContentKey contentType: unused")
  of blockBody:
    let
      # TODO: Need to get the header (or just tx root/uncle root/withdrawals root) from the EL client via
      # JSON-RPC.
      # OR if directly integrated the EL client, we can just pass the header here.
      header = Header()
      blockBody = decodeRlp(content, BlockBody).valueOr:
        return err("Error decoding block body: " & error)
    validateBlockBody(blockBody, header).isOkOr:
      return err("Failed validating block body: " & error)

    ok()
  of receipts:
    let
      # TODO: Need to get the header (or just tx root/uncle root/withdrawals root) from the EL client via
      # JSON-RPC.
      # OR if directly integrated the EL client, we can just pass the header here.
      header = Header()
      receipts = decodeRlp(content, seq[Receipt]).valueOr:
        return err("Error decoding receipts: " & error)
    validateReceipts(receipts, header.receiptsRoot).isOkOr:
      return err("Failed validating receipts: " & error)

    ok()

proc validateContent(
    n: FinalizedHistoryNetwork,
    srcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    contentItems: seq[seq[byte]],
): Future[bool] {.async: (raises: [CancelledError]).} =
  # content passed here can have less items then contentKeys, but not more.
  for i, contentItem in contentItems:
    let contentKey = contentKeys[i]
    let res = await n.validateContent(contentItem, contentKey)
    if res.isOk():
      let contentId = n.portalProtocol.toContentId(contentKey).valueOr:
        warn "Received offered content with invalid content key", srcNodeId, contentKey
        return false

      n.portalProtocol.storeContent(
        contentKey, contentId, contentItem, cacheOffer = true
      )

      debug "Received offered content validated successfully", srcNodeId, contentKey
    else:
      if srcNodeId.isSome():
        n.portalProtocol.banNode(srcNodeId.get(), NodeBanDurationOfferFailedValidation)

      debug "Received offered content failed validation",
        srcNodeId, contentKey, error = res.error
      return false

  return true

proc contentQueueWorker(n: FinalizedHistoryNetwork) {.async: (raises: []).} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentItems) = await n.contentQueue.popFirst()

      if await n.validateContent(srcNodeId, contentKeys, contentItems):
        portal_offer_validation_successful.inc(
          labelValues = [$n.portalProtocol.protocolId]
        )

        discard await n.portalProtocol.neighborhoodGossip(
          srcNodeId, contentKeys, contentItems
        )
      else:
        portal_offer_validation_failed.inc(labelValues = [$n.portalProtocol.protocolId])
  except CancelledError:
    trace "contentQueueWorker canceled"

proc statusLogLoop(n: FinalizedHistoryNetwork) {.async: (raises: []).} =
  try:
    while true:
      await sleepAsync(60.seconds)

      info "History network status",
        routingTableNodes = n.portalProtocol.routingTable.len()
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: FinalizedHistoryNetwork) =
  info "Starting Portal finalized chain history network",
    protocolId = n.portalProtocol.protocolId

  n.portalProtocol.start()

  for i in 0 ..< n.contentQueueWorkers:
    n.processContentLoops.add(contentQueueWorker(n))

  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: FinalizedHistoryNetwork) {.async: (raises: []).} =
  info "Stopping Portal finalized chain history network"

  var futures: seq[Future[void]]
  futures.add(n.portalProtocol.stop())

  for loop in n.processContentLoops:
    futures.add(loop.cancelAndWait())
  if not n.statusLogLoop.isNil:
    futures.add(n.statusLogLoop.cancelAndWait())
  await noCancel(allFutures(futures))

  n.processContentLoops.setLen(0)
  n.statusLogLoop = nil
