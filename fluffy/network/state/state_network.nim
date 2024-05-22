# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  results,
  chronos,
  chronicles,
  eth/common/eth_hash,
  eth/common,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../database/content_db,
  ../history/history_network,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./state_content,
  ./state_validation,
  ./state_gossip

export results

logScope:
  topics = "portal_state"

const stateProtocolId* = [byte 0x50, 0x0A]

type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  processContentLoop: Future[void]
  historyNetwork: Opt[HistoryNetwork]

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc new*(
    T: type StateNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
    historyNetwork = Opt.none(HistoryNetwork),
): T =
  let cq = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

  let s = streamManager.registerNewStream(cq)

  let portalProtocol = PortalProtocol.new(
    baseProtocol,
    stateProtocolId,
    toContentIdHandler,
    createGetHandler(contentDB),
    s,
    bootstrapRecords,
    config = portalConfig,
  )

  portalProtocol.dbPut =
    createStoreHandler(contentDB, portalConfig.radiusConfig, portalProtocol)

  return StateNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: cq,
    historyNetwork: historyNetwork,
  )

# TODO: implement content lookups for each type
proc getContent*(
    n: StateNetwork, contentKey: ContentKey
): Future[Opt[seq[byte]]] {.async.} =
  let
    contentKeyBytes = contentKey.encode()
    contentId = contentKeyBytes.toContentId()
    contentInRange = n.portalProtocol.inRange(contentId)

  # When the content id is in the radius range, try to look it up in the db.
  if contentInRange:
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      return contentFromDB

  let
    contentLookupResult = (
      await n.portalProtocol.contentLookup(contentKeyBytes, contentId)
    ).valueOr:
      return Opt.none(seq[byte])
    contentValueBytes = contentLookupResult.content

  case contentKey.contentType
  of unused:
    error "Received content with unused content type"
    return Opt.none(seq[byte])
  of accountTrieNode:
    let contentValue = AccountTrieNodeRetrieval.decode(contentValueBytes).valueOr:
      error "Unable to decode AccountTrieNodeRetrieval content value"
      return Opt.none(seq[byte])

    validateRetrieval(contentKey.accountTrieNodeKey, contentValue).isOkOr:
      error "Validation of retrieval content failed: ", error
      return Opt.none(seq[byte])
  of contractTrieNode:
    let contentValue = ContractTrieNodeRetrieval.decode(contentValueBytes).valueOr:
      error "Unable to decode ContractTrieNodeRetrieval content value"
      return Opt.none(seq[byte])

    validateRetrieval(contentKey.contractTrieNodeKey, contentValue).isOkOr:
      error "Validation of retrieval content failed: ", error
      return Opt.none(seq[byte])
  of contractCode:
    let contentValue = ContractCodeRetrieval.decode(contentValueBytes).valueOr:
      error "Unable to decode ContractCodeRetrieval content value"
      return Opt.none(seq[byte])

    validateRetrieval(contentKey.contractCodeKey, contentValue).isOkOr:
      error "Validation of retrieval content failed: ", error
      return Opt.none(seq[byte])

  # When content is in the radius range, store it.
  if contentInRange:
    # TODO Add poke when working on state network
    # TODO When working on state network, make it possible to pass different
    # distance functions to store content
    n.portalProtocol.storeContent(contentKeyBytes, contentId, contentValueBytes)

  # TODO: for now returning bytes, ultimately it would be nice to return proper
  # domain types.
  return Opt.some(contentValueBytes)

func decodeKey(contentKey: ByteList): Opt[ContentKey] =
  let key = ContentKey.decode(contentKey).valueOr:
    return Opt.none(ContentKey)

  Opt.some(key)

proc getStateRootByBlockHash(
    n: StateNetwork, hash: BlockHash
): Future[Opt[KeccakHash]] {.async.} =
  if n.historyNetwork.isNone():
    warn "History network is not available. Unable to get state root by block hash"
    return Opt.none(KeccakHash)

  let header = (await n.historyNetwork.get().getVerifiedBlockHeader(hash)).valueOr:
    warn "Failed to get block header by hash", hash
    return Opt.none(KeccakHash)

  Opt.some(header.stateRoot)

proc processOffer[K, V](
    n: StateNetwork,
    maybeSrcNodeId: Opt[NodeId],
    contentKeyBytes: ByteList,
    contentKey: K,
    contentValue: V,
): Future[Result[void, string]] {.async.} =
  mixin blockHash, validateOffer, toRetrievalValue, gossipOffer

  let stateRoot = (await n.getStateRootByBlockHash(contentValue.blockHash)).valueOr:
    return err("Failed to get state root by block hash")

  let res = validateOffer(stateRoot, contentKey, contentValue)
  if res.isErr():
    return err("Received offered content failed validation: " & res.error())

  let contentId = n.portalProtocol.toContentId(contentKeyBytes).valueOr:
    return err("Received offered content with invalid content key")

  n.portalProtocol.storeContent(
    contentKeyBytes, contentId, contentValue.toRetrievalValue().encode()
  )
  info "Received offered content validated successfully", contentKeyBytes

  await gossipOffer(n.portalProtocol, maybeSrcNodeId, contentKey, contentValue)

proc processContentLoop(n: StateNetwork) {.async.} =
  try:
    while true:
      let (maybeSrcNodeId, contentKeys, contentValues) = await n.contentQueue.popFirst()
      for i, contentValueBytes in contentValues:
        let
          contentKeyBytes = contentKeys[i]
          contentKey = decodeKey(contentKeyBytes).valueOr:
            error "Unable to decode offered content key", contentKeyBytes
            continue

        let offerRes =
          case contentKey.contentType
          of unused:
            error "Received content with unused content type"
            continue
          of accountTrieNode:
            let contentValue = AccountTrieNodeOffer.decode(contentValueBytes).valueOr:
              error "Unable to decode offered AccountTrieNodeOffer content value"
              continue

            await processOffer(
              n, maybeSrcNodeId, contentKeyBytes, contentKey.accountTrieNodeKey,
              contentValue,
            )
          of contractTrieNode:
            let contentValue = ContractTrieNodeOffer.decode(contentValueBytes).valueOr:
              error "Unable to decode offered ContractTrieNodeOffer content value"
              continue

            await processOffer(
              n, maybeSrcNodeId, contentKeyBytes, contentKey.contractTrieNodeKey,
              contentValue,
            )
          of contractCode:
            let contentValue = ContractCodeOffer.decode(contentValueBytes).valueOr:
              error "Unable to decode offered ContractCodeOffer content value"
              continue

            await processOffer(
              n, maybeSrcNodeId, contentKeyBytes, contentKey.contractCodeKey,
              contentValue,
            )
        if offerRes.isOk():
          info "Offered content processed successfully", contentKeyBytes
        else:
          error "Offered content processing failed",
            contentKeyBytes, error = offerRes.error()
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
    n.processContentLoop.cancelSoon()
