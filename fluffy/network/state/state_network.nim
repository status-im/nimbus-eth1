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

export results, state_content

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

proc getContent(
    n: StateNetwork,
    key: AccountTrieNodeKey | ContractTrieNodeKey | ContractCodeKey,
    V: type ContentRetrievalType,
): Future[Opt[V]] {.async.} =
  let
    contentKeyBytes = key.toContentKey().encode()
    contentId = contentKeyBytes.toContentId()

  if n.portalProtocol.inRange(contentId):
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      let contentValue = V.decode(contentFromDB.get()).valueOr:
        error "Unable to decode account trie node content value from database"
        return Opt.none(V)

      info "Fetched account trie node from database"
      return Opt.some(contentValue)

  let
    contentLookupResult = (
      await n.portalProtocol.contentLookup(contentKeyBytes, contentId)
    ).valueOr:
      return Opt.none(V)
    contentValueBytes = contentLookupResult.content

  let contentValue = V.decode(contentValueBytes).valueOr:
    error "Unable to decode account trie node content value from content lookup"
    return Opt.none(V)

  validateRetrieval(key, contentValue).isOkOr:
    error "Validation of retrieved content failed"
    return Opt.none(V)

  n.portalProtocol.storeContent(contentKeyBytes, contentId, contentValueBytes)

  return Opt.some(contentValue)

proc getAccountTrieNode*(
    n: StateNetwork, key: AccountTrieNodeKey
): Future[Opt[AccountTrieNodeRetrieval]] {.inline.} =
  n.getContent(key, AccountTrieNodeRetrieval)

proc getContractTrieNode*(
    n: StateNetwork, key: ContractTrieNodeKey
): Future[Opt[ContractTrieNodeRetrieval]] {.inline.} =
  n.getContent(key, ContractTrieNodeRetrieval)

proc getContractCode*(
    n: StateNetwork, key: ContractCodeKey
): Future[Opt[ContractCodeRetrieval]] {.inline.} =
  n.getContent(key, ContractCodeRetrieval)

# High level endpoints
# eth_getBalance
# eth_getStorageAt
# eth_getCode

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

proc processOffer(
    n: StateNetwork,
    maybeSrcNodeId: Opt[NodeId],
    contentKeyBytes: ByteList,
    contentValueBytes: seq[byte],
    contentKey: AccountTrieNodeKey | ContractTrieNodeKey | ContractCodeKey,
    V: type ContentOfferType,
): Future[Result[void, string]] {.async.} =
  let contentValue = V.decode(contentValueBytes).valueOr:
    return err("Unable to decode offered content value")

  let stateRoot = (await n.getStateRootByBlockHash(contentValue.blockHash)).valueOr:
    return err("Failed to get state root by block hash")

  let res = validateOffer(stateRoot, contentKey, contentValue)
  if res.isErr():
    return err("Offered content failed validation: " & res.error())

  let contentId = n.portalProtocol.toContentId(contentKeyBytes).valueOr:
    return err("Received offered content with invalid content key")

  n.portalProtocol.storeContent(
    contentKeyBytes, contentId, contentValue.toRetrievalValue().encode()
  )
  info "Offered content validated successfully", contentKeyBytes

  asyncSpawn gossipOffer(
    n.portalProtocol, maybeSrcNodeId, contentKeyBytes, contentValueBytes, contentKey,
    contentValue,
  )

  ok()

proc processContentLoop(n: StateNetwork) {.async.} =
  try:
    while true:
      let (srcNodeId, contentKeys, contentValues) = await n.contentQueue.popFirst()
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
            await n.processOffer(
              srcNodeId, contentKeyBytes, contentValueBytes,
              contentKey.accountTrieNodeKey, AccountTrieNodeOffer,
            )
          of contractTrieNode:
            await n.processOffer(
              srcNodeId, contentKeyBytes, contentValueBytes,
              contentKey.contractTrieNodeKey, ContractTrieNodeOffer,
            )
          of contractCode:
            await n.processOffer(
              srcNodeId, contentKeyBytes, contentValueBytes, contentKey.contractCodeKey,
              ContractCodeOffer,
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
