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
  "."/[history_content, history_validation]

from eth/common/accounts import EMPTY_ROOT_HASH

export history_content, headers

logScope:
  topics = "portal_fin_hist"

const pingExtensionCapabilities = {CapabilitiesType, HistoryRadiusType}

type
  GetHeaderCallback* = proc(blockNumber: uint64): Future[Result[Header, string]] {.
    async: (raises: [CancelledError]), gcsafe
  .}

  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
    getHeader*: GetHeaderCallback
    # cfg*: RuntimeConfig
    processContentLoops: seq[Future[void]]
    statusLogLoop: Future[void]
    contentRequestRetries: int
    contentQueueWorkers: int

proc defaultNoGetHeader*(
    blockNumber: uint64
): Future[Result[Header, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  err(
    "No getHeader callback set for PortalNode, cannot verify offered content for block: " &
      $blockNumber
  )

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  toContentId(contentKey)

proc new*(
    T: type HistoryNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    getHeaderCallback: GetHeaderCallback = defaultNoGetHeader,
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
      getProtocolId(portalNetwork, PortalSubnetwork.history),
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

  HistoryNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: contentQueue,
    getHeader: getHeaderCallback,
    # cfg: cfg,
    contentRequestRetries: contentRequestRetries,
    contentQueueWorkers: contentQueueWorkers,
  )

func localNode*(n: HistoryNetwork): Node =
  n.portalProtocol.localNode()

proc getContent*(
    n: HistoryNetwork, contentKey: ContentKey, V: type ContentValueType, header: Header
): Future[Opt[V]] {.async: (raises: [CancelledError]).} =
  ## Get the decoded content for the given content key.
  ##
  ## When the content is found locally, no validation is performed.
  ## Else, the content is fetched from the network and validated with the provided header.
  ## If content validation fails, the node is banned for a certain period of time and
  ## content request is retried `contentRequestRetries` times.
  let contentKeyBytes = encode(contentKey)

  logScope:
    contentKeyBytes

  let contentId = contentKeyBytes.toContentId().valueOr:
    warn "Received invalid content key", contentKeyBytes
    return Opt.none(V)

  # Check first locally
  n.portalProtocol.getLocalContent(contentKeyBytes, contentId).isErrOr:
    let contentValue = decodeRlp(value(), V).valueOr:
      raiseAssert("Unable to decode history local content value")

    debug "Fetched local content value"
    return Opt.some(contentValue)

  for i in 0 ..< (1 + n.contentRequestRetries):
    let
      lookupRes = (await n.portalProtocol.contentLookup(contentKeyBytes, contentId)).valueOr:
        warn "Failed fetching content from the network"
        return Opt.none(V)

      contentValue = decodeRlp(lookupRes.content, V).valueOr:
        warn "Unable to decode content value from content lookup"
        continue

    validateContent(contentValue, header).isOkOr:
      n.portalProtocol.banNode(
        lookupRes.receivedFrom.id, NodeBanDurationContentLookupFailedValidation
      )
      warn "Error validating retrieved content", error = error
      continue

    debug "Fetched valid content from the network"
    n.portalProtocol.storeContent(
      contentKeyBytes, contentId, lookupRes.content, cacheContent = true
    )

    asyncSpawn n.portalProtocol.triggerPoke(
      lookupRes.nodesInterestedInContent, contentKeyBytes, lookupRes.content
    )

    return Opt.some(contentValue)

  # Content was requested `1 + requestRetries` times and all failed on validation
  Opt.none(V)

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKeyBytes: ContentKeyByteList
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  # TODO: specs might turn out to just disable offers. Although I think for for getting initial data in the network
  # this might be an issue. Unless history expiry gets deployed together with Portal.
  let contentKey = history_content.decode(contentKeyBytes).valueOr:
    return err("Error decoding content key")

  let header = ?(await n.getHeader(contentKey.blockNumber()))

  case contentKey.contentType
  of blockBody:
    let blockBody = decodeRlp(content, BlockBody).valueOr:
      return err("Error decoding block body: " & error)
    validateBlockBody(blockBody, header).isOkOr:
      return err("Failed validating block body: " & error)

    ok()
  of receipts:
    let receipts = decodeRlp(content, StoredReceipts).valueOr:
      return err("Error decoding receipts: " & error)
    validateReceipts(receipts, header).isOkOr:
      return err("Failed validating receipts: " & error)

    ok()

proc validateContent(
    n: HistoryNetwork,
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

proc contentQueueWorker(n: HistoryNetwork) {.async: (raises: []).} =
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

proc statusLogLoop(n: HistoryNetwork) {.async: (raises: []).} =
  try:
    while true:
      await sleepAsync(60.seconds)

      info "History network status",
        routingTableNodes = n.portalProtocol.routingTable.len()
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: HistoryNetwork) =
  info "Starting Portal chain history network", protocolId = n.portalProtocol.protocolId

  n.portalProtocol.start()

  for i in 0 ..< n.contentQueueWorkers:
    n.processContentLoops.add(contentQueueWorker(n))

  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: HistoryNetwork) {.async: (raises: []).} =
  info "Stopping Portal chain history network"

  var futures: seq[Future[void]]
  futures.add(n.portalProtocol.stop())

  for loop in n.processContentLoops:
    futures.add(loop.cancelAndWait())
  if not n.statusLogLoop.isNil:
    futures.add(n.statusLogLoop.cancelAndWait())
  await noCancel(allFutures(futures))

  n.processContentLoops.setLen(0)
  n.statusLogLoop = nil
