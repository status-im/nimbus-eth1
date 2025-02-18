# Fluffy
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  eth/trie/ordered_trie,
  eth/common/[hashes, headers_rlp, blocks_rlp, receipts_rlp, transactions_rlp],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../common/common_types,
  ../../database/content_db,
  ../../network_metadata,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config, ping_extensions],
  "."/[history_content, history_validation, history_type_conversions],
  ../beacon/beacon_chain_historical_roots

from eth/common/eth_types_rlp import rlpHash
from eth/common/accounts import EMPTY_ROOT_HASH

logScope:
  topics = "portal_hist"

export blocks_rlp

const pingExtensionCapabilities = {CapabilitiesType, HistoryRadiusType}

type
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
    accumulator*: FinishedHistoricalHashesAccumulator
    historicalRoots*: HistoricalRoots
    processContentLoop: Future[void]
    statusLogLoop: Future[void]
    contentRequestRetries: int

  Block* = (Header, BlockBody)

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

## Get local content calls

proc getLocalContent(
    n: HistoryNetwork,
    T: type Header,
    contentKey: ContentKeyByteList,
    contentId: ContentId,
): Opt[T] =
  let
    localContent = n.portalProtocol.getLocalContent(contentKey, contentId).valueOr:
      return Opt.none(T)

    # Stored data should always be serialized correctly
    headerWithProof = decodeSszOrRaise(localContent, BlockHeaderWithProof)
    header = decodeRlpOrRaise(headerWithProof.header.asSeq(), T)

  Opt.some(header)

proc getLocalContent(
    n: HistoryNetwork,
    T: type BlockBody,
    contentKey: ContentKeyByteList,
    contentId: ContentId,
    header: Header,
): Opt[T] =
  let localContent = n.portalProtocol.getLocalContent(contentKey, contentId).valueOr:
    return Opt.none(T)

  let
    timestamp = Moment.init(header.timestamp.int64, Second)
    body =
      if isShanghai(chainConfig, timestamp):
        BlockBody.fromPortalBlockBodyOrRaise(
          decodeSszOrRaise(localContent, PortalBlockBodyShanghai)
        )
      elif isPoSBlock(chainConfig, header.number):
        BlockBody.fromPortalBlockBodyOrRaise(
          decodeSszOrRaise(localContent, PortalBlockBodyLegacy)
        )
      else:
        BlockBody.fromPortalBlockBodyOrRaise(
          decodeSszOrRaise(localContent, PortalBlockBodyLegacy)
        )

  Opt.some(body)

proc getLocalContent(
    n: HistoryNetwork,
    T: type seq[Receipt],
    contentKey: ContentKeyByteList,
    contentId: ContentId,
): Opt[T] =
  let
    localContent = n.portalProtocol.getLocalContent(contentKey, contentId).valueOr:
      return Opt.none(T)

    # Stored data should always be serialized correctly
    portalReceipts = decodeSszOrRaise(localContent, PortalReceipts)
    receipts = T.fromPortalReceipts(portalReceipts).valueOr:
      raiseAssert(error)

  Opt.some(receipts)

## Public API to get the history network specific types, either from database
## or through a lookup on the Portal Network

# TODO: Currently doing retries on lookups but only when the validation fails.
# This is to avoid nodes that provide garbage from blocking us with getting the
# requested data. Might want to also do that on a failed lookup, as perhaps this
# could occur when being really unlucky with nodes timing out on requests.
# Additionally, more improvements could be done with the lookup, as currently
# ongoing requests are cancelled after the receival of the first response,
# however that response is not yet validated at that moment.

proc getVerifiedBlockHeader*(
    n: HistoryNetwork, id: Hash32 | uint64
): Future[Opt[Header]] {.async: (raises: [CancelledError]).} =
  let
    contentKey = blockHeaderContentKey(id).encode()
    contentId = history_content.toContentId(contentKey)

  logScope:
    id
    contentKey

  # Note: This still requests a BlockHeaderWithProof from the database, as that
  # is what is stored. But the proof doesn't need to be verified as it gets
  # gets verified before storing.
  let localContent = n.getLocalContent(Header, contentKey, contentId)
  if localContent.isSome():
    debug "Fetched block header locally"
    return localContent

  for i in 0 ..< (1 + n.contentRequestRetries):
    let
      headerContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        debug "Failed fetching block header with proof from the network"
        return Opt.none(Header)

      header = validateCanonicalHeaderBytes(headerContent.content, id, n.accumulator).valueOr:
        n.portalProtocol.banNode(
          headerContent.receivedFrom.id, NodeBanDurationContentLookupFailedValidation
        )
        warn "Validation of block header failed",
          error = error, node = headerContent.receivedFrom.record.toURI()
        continue

    debug "Fetched valid block header from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(
      contentKey, contentId, headerContent.content, cacheContent = true
    )
    n.portalProtocol.triggerPoke(
      headerContent.nodesInterestedInContent, contentKey, headerContent.content
    )

    return Opt.some(header)

  # Headers were requested `1 + requestRetries` times and all failed on validation
  Opt.none(Header)

proc getBlockBody*(
    n: HistoryNetwork, blockHash: Hash32, header: Header
): Future[Opt[BlockBody]] {.async: (raises: [CancelledError]).} =
  if header.txRoot == EMPTY_ROOT_HASH and header.ommersHash == EMPTY_UNCLE_HASH:
    # Short path for empty body indicated by txRoot and ommersHash
    return Opt.some(BlockBody(transactions: @[], uncles: @[]))

  let
    contentKey = blockBodyContentKey(blockHash).encode()
    contentId = contentKey.toContentId()

  logScope:
    blockHash
    contentKey

  let localContent = n.getLocalContent(BlockBody, contentKey, contentId, header)
  if localContent.isSome():
    debug "Fetched block body locally"
    return localContent

  for i in 0 ..< (1 + n.contentRequestRetries):
    let
      bodyContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        debug "Failed fetching block body from the network"
        return Opt.none(BlockBody)

      body = validateBlockBodyBytes(bodyContent.content, header).valueOr:
        n.portalProtocol.banNode(
          bodyContent.receivedFrom.id, NodeBanDurationContentLookupFailedValidation
        )
        warn "Validation of block body failed",
          error, node = bodyContent.receivedFrom.record.toURI()
        continue

    debug "Fetched block body from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(
      contentKey, contentId, bodyContent.content, cacheContent = true
    )
    n.portalProtocol.triggerPoke(
      bodyContent.nodesInterestedInContent, contentKey, bodyContent.content
    )

    return Opt.some(body)

  # Bodies were requested `1 + requestRetries` times and all failed on validation
  Opt.none(BlockBody)

proc getBlock*(
    n: HistoryNetwork, id: Hash32 | uint64
): Future[Opt[Block]] {.async: (raises: [CancelledError]).} =
  debug "Trying to retrieve block", id

  # Note: Using `getVerifiedBlockHeader` instead of getBlockHeader even though
  # proofs are not necessiarly needed, in order to avoid having to inject
  # also the original type into the network.
  let
    header = (await n.getVerifiedBlockHeader(id)).valueOr:
      debug "Failed to get header when getting block", id
      return Opt.none(Block)
    hash =
      when id is Hash32:
        id
      else:
        header.rlpHash()
    body = (await n.getBlockBody(hash, header)).valueOr:
      debug "Failed to get body when getting block", hash
      return Opt.none(Block)

  Opt.some((header, body))

proc getBlockHashByNumber*(
    n: HistoryNetwork, blockNumber: uint64
): Future[Result[Hash32, string]] {.async: (raises: [CancelledError]).} =
  let header = (await n.getVerifiedBlockHeader(blockNumber)).valueOr:
    return err("Cannot retrieve block header for given block number")

  ok(header.rlpHash())

proc getReceipts*(
    n: HistoryNetwork, blockHash: Hash32, header: Header
): Future[Opt[seq[Receipt]]] {.async: (raises: [CancelledError]).} =
  if header.receiptsRoot == EMPTY_ROOT_HASH:
    # Short path for empty receipts indicated by receipts root
    return Opt.some(newSeq[Receipt]())

  let
    contentKey = receiptsContentKey(blockHash).encode()
    contentId = contentKey.toContentId()

  logScope:
    blockHash
    contentKey

  let localContent = n.getLocalContent(seq[Receipt], contentKey, contentId)
  if localContent.isSome():
    debug "Fetched receipts locally"
    return localContent

  for i in 0 ..< (1 + n.contentRequestRetries):
    let
      receiptsContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        debug "Failed fetching receipts from the network"
        return Opt.none(seq[Receipt])

      receipts = validateReceiptsBytes(receiptsContent.content, header.receiptsRoot).valueOr:
        n.portalProtocol.banNode(
          receiptsContent.receivedFrom.id, NodeBanDurationContentLookupFailedValidation
        )
        warn "Validation of receipts failed",
          error, node = receiptsContent.receivedFrom.record.toURI()
        continue

    debug "Fetched receipts from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(
      contentKey, contentId, receiptsContent.content, cacheContent = true
    )
    n.portalProtocol.triggerPoke(
      receiptsContent.nodesInterestedInContent, contentKey, receiptsContent.content
    )

    return Opt.some(receipts)

  # Receipts were requested `1 + requestRetries` times and all failed on validation
  Opt.none(seq[Receipt])

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKeyBytes: ContentKeyByteList
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let contentKey = contentKeyBytes.decode().valueOr:
    return err("Error decoding content key")

  case contentKey.contentType
  of blockHeader:
    let _ = validateCanonicalHeaderBytes(
      content, contentKey.blockHeaderKey.blockHash, n.accumulator
    ).valueOr:
      return err("Failed validating block header: " & error)

    ok()
  of blockBody:
    let
      header = (await n.getVerifiedBlockHeader(contentKey.blockBodyKey.blockHash)).valueOr:
        return err("Failed getting canonical header for block")
      _ = validateBlockBodyBytes(content, header).valueOr:
        return err("Failed validating block body: " & error)

    ok()
  of receipts:
    let
      header = (await n.getVerifiedBlockHeader(contentKey.receiptsKey.blockHash)).valueOr:
        return err("Failed getting canonical header for receipts")
      _ = validateReceiptsBytes(content, header.receiptsRoot).valueOr:
        return err("Failed validating receipts: " & error)

    ok()
  of blockNumber:
    let _ = validateCanonicalHeaderBytes(
      content, contentKey.blockNumberKey.blockNumber, n.accumulator
    ).valueOr:
      return err("Failed validating block header: " & error)

    ok()
  of ephemeralBlockHeader:
    err("Ephemeral block headers are not yet supported")

proc new*(
    T: type HistoryNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    accumulator: FinishedHistoricalHashesAccumulator,
    historicalRoots: HistoricalRoots = loadHistoricalRoots(),
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
    contentRequestRetries = 1,
): T =
  let
    contentQueue = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

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
    accumulator: accumulator,
    historicalRoots: historicalRoots,
    contentRequestRetries: contentRequestRetries,
  )

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

      n.portalProtocol.storeContent(contentKey, contentId, contentItem)

      debug "Received offered content validated successfully", srcNodeId, contentKey
    else:
      if srcNodeId.isSome():
        n.portalProtocol.banNode(srcNodeId.get(), NodeBanDurationOfferFailedValidation)

      debug "Received offered content failed validation",
        srcNodeId, contentKey, error = res.error
      return false

  return true

proc processContentLoop(n: HistoryNetwork) {.async: (raises: []).} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentItems) = await n.contentQueue.popFirst()

      # When there is one invalid content item, all other content items are
      # dropped and not gossiped around.
      # TODO: Differentiate between failures due to invalid data and failures
      # due to missing network data for validation.
      if await n.validateContent(srcNodeId, contentKeys, contentItems):
        asyncSpawn n.portalProtocol.neighborhoodGossipDiscardPeers(
          srcNodeId, contentKeys, contentItems
        )
  except CancelledError:
    trace "processContentLoop canceled"

proc statusLogLoop(n: HistoryNetwork) {.async: (raises: []).} =
  try:
    while true:
      info "History network status",
        routingTableNodes = n.portalProtocol.routingTable.len()

      await sleepAsync(60.seconds)
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: HistoryNetwork) =
  info "Starting Portal execution history network",
    protocolId = n.portalProtocol.protocolId,
    accumulatorRoot = hash_tree_root(n.accumulator)

  n.portalProtocol.start()

  n.processContentLoop = processContentLoop(n)
  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: HistoryNetwork) {.async: (raises: []).} =
  info "Stopping Portal execution history network"

  var futures: seq[Future[void]]
  futures.add(n.portalProtocol.stop())

  if not n.processContentLoop.isNil:
    futures.add(n.processContentLoop.cancelAndWait())
  if not n.statusLogLoop.isNil:
    futures.add(n.statusLogLoop.cancelAndWait())
  await noCancel(allFutures(futures))

  n.processContentLoop = nil
  n.statusLogLoop = nil
