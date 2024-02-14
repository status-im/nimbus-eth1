# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/results, chronos, chronicles,
  eth/common/eth_hash,
  eth/common,
  eth/p2p/discoveryv5/[protocol, enr],
  ../../database/content_db,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./state_content

logScope:
  topics = "portal_state"

const
  stateProtocolId* = [byte 0x50, 0x0A]

type StateNetwork* = ref object
  portalProtocol*: PortalProtocol
  contentDB*: ContentDB
  contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
  processContentLoop: Future[void]

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

proc getContent*(n: StateNetwork, key: ContentKey):
    Future[Opt[seq[byte]]] {.async.} =
  let
    keyEncoded = encode(key)
    contentId = toContentId(key)
    contentInRange = n.portalProtocol.inRange(contentId)

  # When the content id is in the radius range, try to look it up in the db.
  if contentInRange:
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      return contentFromDB

  let content = await n.portalProtocol.contentLookup(keyEncoded, contentId)

  if content.isNone():
    return Opt.none(seq[byte])

  let contentResult = content.get()

  # When content is found on the network and is in the radius range, store it.
  if content.isSome() and contentInRange:
    # TODO Add poke when working on state network
    # TODO When working on state network, make it possible to pass different
    # distance functions to store content
    n.portalProtocol.storeContent(keyEncoded, contentId, contentResult.content)

  # TODO: for now returning bytes, ultimately it would be nice to return proper
  # domain types.
  return Opt.some(contentResult.content)

proc validateAccountTrieNode(key: ContentKey, contentValue: seq[byte]): bool =
  let value = decodeSsz(contentValue, AccountTrieNodeOffer).valueOr:
      warn "Received invalid account trie proof", error
      return false
  true

proc validateContractTrieNode(key: ContentKey, contentValue: seq[byte]): bool =
  let value = decodeSsz(contentValue, ContractTrieNodeOffer).valueOr:
    warn "Received invalid contract trie proof", error
    return false
  true

proc validateContractCode(key: ContentKey, contentValue: seq[byte]): bool =
  let value = decodeSsz(contentValue, ContractCodeOffer).valueOr:
    warn "Received invalid contract code", error
    return false
  true

proc validateContent*(
    n: StateNetwork,
    contentKey: ByteList,
    contentValue: seq[byte]): bool =
  let key = contentKey.decode().valueOr:
    return false
  
  case key.contentType:
    of unused:
      warn "Received content with unused content type"
      false
    of accountTrieNode:
      validateAccountTrieNode(key, contentValue)
    of contractTrieNode:
      validateContractTrieNode(key, contentValue)
    of contractCode:
      validateContractCode(key, contentValue)

proc validateContent(
    n: StateNetwork,
    contentKeys: ContentKeysList,
    contentValues: seq[seq[byte]]): bool =
  for i, contentValue in contentValues:
    let contentKey = contentKeys[i]
    if n.validateContent(contentKey, contentValue):
      let contentId = n.portalProtocol.toContentId(contentKey).valueOr:
        error "Received offered content with invalid content key", contentKey
        return false

      n.portalProtocol.storeContent(contentKey, contentId, contentValue)

      info "Received offered content validated successfully", contentKey
    else:
      error "Received offered content failed validation", contentKey
      return false

proc recursiveGossipAccountTrieNode(
    p: PortalProtocol,
    maybeSrcNodeId: Opt[NodeId],
    decodedKey: ContentKey,
    contentValue: seq[byte],
    gossipProc: proc(
      p: PortalProtocol,
      maybeSrcNodeId: Opt[NodeId],
      contentKeys: ContentKeysList,
      contentValues: seq[seq[byte]]): Future[void] {.async, gcsafe, closure.}
    ): Future[void] {.async.} =
      var nibbles = decodedKey.accountTrieNodeKey.path.unpackNibbles()
      let decodedValue = decodeSsz(contentValue, AccountTrieNodeOffer).valueOr:
        raiseAssert "Received offered content failed validation"
      var proof = decodedValue.proof
      discard nibbles.pop()
      discard (distinctBase proof).pop()
      let
        updatedValue = AccountTrieNodeOffer(
          proof: proof,
          blockHash: decodedValue.blockHash,
        )
        updatedNodeHash = keccakHash(distinctBase proof[^1])
        encodedValue = SSZ.encode(updatedValue)
        updatedKey = AccountTrieNodeKey(path: nibbles.packNibbles(), nodeHash: updatedNodeHash)
        encodedKey = ContentKey(accountTrieNodeKey: updatedKey, contentType: accountTrieNode).encode()

      await gossipProc(
        p, maybeSrcNodeId, ContentKeysList.init(@[encodedKey]), @[encodedValue]
      )

proc recursiveGossipContractTrieNode(
    p: PortalProtocol,
    maybeSrcNodeId: Opt[NodeId],
    decodedKey: ContentKey,
    contentValue: seq[byte],
    gossipProc: proc(
      p: PortalProtocol,
      maybeSrcNodeId: Opt[NodeId],
      contentKeys: ContentKeysList,
      contentValues: seq[seq[byte]]): Future[void] {.async, gcsafe, closure.}
    ): Future[void] {.async.} =
      return

proc gossipContent*(
    p: PortalProtocol,
    maybeSrcNodeId: Opt[NodeId],
    contentKeys: ContentKeysList,
    contentValues: seq[seq[byte]],
    gossipProc: proc(
      p: PortalProtocol,
      maybeSrcNodeId: Opt[NodeId],
      contentKeysList: ContentKeysList,
      contentValues: seq[seq[byte]]): Future[void] {.async, gcsafe, closure.}
    ): Future[void] {.async.} =
  for i, contentValue in contentValues:
    let
      contentKey = contentKeys[i]
      decodedKey = contentKey.decode().valueOr:
        raiseAssert "Received offered content with invalid content key"
    case decodedKey.contentType:
      of unused:
        warn("Gossiping content with unused content type")
        continue
      of accountTrieNode:
        await recursiveGossipAccountTrieNode(p, maybeSrcNodeId, decodedKey, contentValue, gossipProc)
      of contractTrieNode:
        await recursiveGossipContractTrieNode(p, maybeSrcNodeId, decodedKey, contentValue, gossipProc)
      of contractCode:
        await gossipProc(
          p, maybeSrcNodeId, ContentKeysList.init(@[contentKey]), @[contentValue]
        )

proc new*(
    T: type StateNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =

  let cq = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

  let s = streamManager.registerNewStream(cq)

  let portalProtocol = PortalProtocol.new(
    baseProtocol, stateProtocolId,
    toContentIdHandler, createGetHandler(contentDB), s,
    bootstrapRecords, config = portalConfig)

  portalProtocol.dbPut = createStoreHandler(contentDB, portalConfig.radiusConfig, portalProtocol)

  return StateNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: cq
  )

proc processContentLoop(n: StateNetwork) {.async.} =
  try:
    while true:
      let (maybeSrcNodeId, contentKeys, contentValues) = await n.contentQueue.popFirst()
      if n.validateContent(contentKeys, contentValues):
        await gossipContent(
          n.portalProtocol,
          maybeSrcNodeId,
          contentKeys,
          contentValues,
          randomGossipDiscardPeers
          )
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
