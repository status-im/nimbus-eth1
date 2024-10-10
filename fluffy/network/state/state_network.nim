# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  results,
  chronos,
  chronicles,
  eth/common/hashes,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../database/content_db,
  ../history/history_network,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./state_content,
  ./state_validation,
  ./state_gossip

export results, state_content, hashes

logScope:
  topics = "portal_state"

type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  processContentLoop: Future[void]
  statusLogLoop: Future[void]
  historyNetwork: Opt[HistoryNetwork]
  validateStateIsCanonical: bool

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc new*(
    T: type StateNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
    historyNetwork = Opt.none(HistoryNetwork),
    validateStateIsCanonical = true,
): T =
  let
    cq = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)
    s = streamManager.registerNewStream(cq)
    portalProtocol = PortalProtocol.new(
      baseProtocol,
      getProtocolId(portalNetwork, PortalSubnetwork.state),
      toContentIdHandler,
      createGetHandler(contentDB),
      createStoreHandler(contentDB, portalConfig.radiusConfig),
      createRadiusHandler(contentDB),
      s,
      bootstrapRecords,
      config = portalConfig,
    )

  StateNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: cq,
    historyNetwork: historyNetwork,
    validateStateIsCanonical: validateStateIsCanonical,
  )

proc getContent(
    n: StateNetwork,
    key: AccountTrieNodeKey | ContractTrieNodeKey | ContractCodeKey,
    V: type ContentRetrievalType,
): Future[Opt[V]] {.async: (raises: [CancelledError]).} =
  let
    contentKeyBytes = key.toContentKey().encode()
    contentId = contentKeyBytes.toContentId()

  if n.portalProtocol.inRange(contentId):
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      let contentValue = V.decode(contentFromDB.get()).valueOr:
        error "Unable to decode state content value from database"
        return Opt.none(V)

      info "Fetched state content value from database"
      return Opt.some(contentValue)

  let
    contentLookupResult = (
      await n.portalProtocol.contentLookup(contentKeyBytes, contentId)
    ).valueOr:
      warn "Failed fetching state content from the network"
      return Opt.none(V)
    contentValueBytes = contentLookupResult.content

  let contentValue = V.decode(contentValueBytes).valueOr:
    warn "Unable to decode state content value from content lookup"
    return Opt.none(V)

  validateRetrieval(key, contentValue).isOkOr:
    warn "Validation of retrieved state content failed"
    return Opt.none(V)

  n.portalProtocol.storeContent(contentKeyBytes, contentId, contentValueBytes)

  Opt.some(contentValue)

proc getAccountTrieNode*(
    n: StateNetwork, key: AccountTrieNodeKey
): Future[Opt[AccountTrieNodeRetrieval]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  n.getContent(key, AccountTrieNodeRetrieval)

proc getContractTrieNode*(
    n: StateNetwork, key: ContractTrieNodeKey
): Future[Opt[ContractTrieNodeRetrieval]] {.
    async: (raw: true, raises: [CancelledError])
.} =
  n.getContent(key, ContractTrieNodeRetrieval)

proc getContractCode*(
    n: StateNetwork, key: ContractCodeKey
): Future[Opt[ContractCodeRetrieval]] {.async: (raw: true, raises: [CancelledError]).} =
  n.getContent(key, ContractCodeRetrieval)

proc getStateRootByBlockNumOrHash*(
    n: StateNetwork, blockNumOrHash: uint64 | Hash32
): Future[Opt[Hash32]] {.async: (raises: [CancelledError]).} =
  let hn = n.historyNetwork.valueOr:
    warn "History network is not available"
    return Opt.none(Hash32)

  let header = (await hn.getVerifiedBlockHeader(blockNumOrHash)).valueOr:
    warn "Failed to get block header from history", blockNumOrHash
    return Opt.none(Hash32)

  Opt.some(header.stateRoot)

proc getStateRootForValidation(
    n: StateNetwork, offer: ContentOfferType
): Future[Result[Opt[Hash32], string]] {.async: (raises: [CancelledError]).} =
  let maybeStateRoot =
    if n.validateStateIsCanonical:
      let stateRoot = (await n.getStateRootByBlockNumOrHash(offer.blockHash)).valueOr:
        return err("Failed to get state root by block hash")
      Opt.some(stateRoot)
    else:
      # Skip state root validation
      Opt.none(Hash32)
  ok(maybeStateRoot)

proc processOffer*(
    n: StateNetwork,
    maybeSrcNodeId: Opt[NodeId],
    contentKeyBytes: ContentKeyByteList,
    contentValueBytes: seq[byte],
    contentKey: AccountTrieNodeKey | ContractTrieNodeKey | ContractCodeKey,
    V: type ContentOfferType,
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  let
    contentValue = V.decode(contentValueBytes).valueOr:
      return err("Unable to decode offered content value")
    maybeStateRoot = ?(await n.getStateRootForValidation(contentValue))
    validationRes = validateOffer(maybeStateRoot, contentKey, contentValue)
  if validationRes.isErr():
    return err("Offered content failed validation: " & validationRes.error())

  let contentId = n.portalProtocol.toContentId(contentKeyBytes).valueOr:
    return err("Received offered content with invalid content key")

  n.portalProtocol.storeContent(
    contentKeyBytes, contentId, contentValue.toRetrievalValue().encode()
  )
  debug "Offered content validated successfully", contentKeyBytes

  await gossipOffer(
    n.portalProtocol, maybeSrcNodeId, contentKeyBytes, contentValueBytes
  )

  ok()

proc processContentLoop(n: StateNetwork) {.async: (raises: []).} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentValues) = await n.contentQueue.popFirst()

      for i, contentBytes in contentValues:
        let
          contentKeyBytes = contentKeys[i]
          contentKey = ContentKey.decode(contentKeyBytes).valueOr:
            error "Unable to decode offered content key", contentKeyBytes
            continue

          offerRes =
            case contentKey.contentType
            of unused:
              error "Received content with unused content type"
              continue
            of accountTrieNode:
              await n.processOffer(
                srcNodeId, contentKeyBytes, contentBytes, contentKey.accountTrieNodeKey,
                AccountTrieNodeOffer,
              )
            of contractTrieNode:
              await n.processOffer(
                srcNodeId, contentKeyBytes, contentBytes,
                contentKey.contractTrieNodeKey, ContractTrieNodeOffer,
              )
            of contractCode:
              await n.processOffer(
                srcNodeId, contentKeyBytes, contentBytes, contentKey.contractCodeKey,
                ContractCodeOffer,
              )
        if offerRes.isOk():
          info "Offered content processed successfully", contentKeyBytes
        else:
          error "Offered content processing failed",
            contentKeyBytes, error = offerRes.error()
  except CancelledError:
    trace "processContentLoop canceled"

proc statusLogLoop(n: StateNetwork) {.async: (raises: []).} =
  try:
    while true:
      info "State network status",
        routingTableNodes = n.portalProtocol.routingTable.len()

      await sleepAsync(60.seconds)
  except CancelledError:
    trace "statusLogLoop canceled"

proc start*(n: StateNetwork) =
  info "Starting Portal execution state network",
    protocolId = n.portalProtocol.protocolId

  n.portalProtocol.start()

  n.processContentLoop = processContentLoop(n)
  n.statusLogLoop = statusLogLoop(n)

proc stop*(n: StateNetwork) {.async: (raises: []).} =
  info "Stopping Portal execution state network"

  var futures: seq[Future[void]]
  futures.add(n.portalProtocol.stop())

  if not n.processContentLoop.isNil():
    futures.add(n.processContentLoop.cancelAndWait())
  if not n.statusLogLoop.isNil():
    futures.add(n.statusLogLoop.cancelAndWait())

  await noCancel(allFutures(futures))

  n.processContentLoop = nil
  n.statusLogLoop = nil
