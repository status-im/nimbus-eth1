# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, sugar],
  stew/results, chronos,
  eth/[common/eth_types, rlp],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../../../nimbus/utils,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./history_content

const
  historyProtocolId* = [byte 0x50, 0x0B]

# TODO: Extract common parts from the different networks
type 
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB

  Block* = (BlockHeader, BlockBody)

func setStreamTransport*(n: HistoryNetwork, transport: UtpDiscv5Protocol) =
  setTransport(n.portalProtocol.stream, transport)

proc toContentIdHandler(contentKey: ByteList): Option[ContentId] =
  some(toContentId(contentKey))


proc encodeKey(k: ContentKey): (ByteList, ContentId) =
  let keyEncoded = encode(k)
  return (keyEncoded, toContentId(keyEncoded))

proc getContent(n: HistoryNetwork, keyEncoded: ByteList, contentId: ContentId):
    Future[Option[seq[byte]]] {.async.} =
  let
    contentInRange = n.portalProtocol.inRange(contentId)

  # When the content id is in the radius range, try to look it up in the db.
  if contentInRange:
    let contentFromDB = n.contentDB.get(contentId)
    if contentFromDB.isSome():
      return contentFromDB

  let content = await n.portalProtocol.contentLookup(keyEncoded, contentId)

  # When content is found and is in the radius range, store it.
  if content.isSome() and contentInRange:
    n.contentDB.put(contentId, content.get())

  # TODO: for now returning bytes, ultimately it would be nice to return proper
  # domain types.
  return content

proc getBlockHeader*(h: HistoryNetwork, chainId: uint16, hash: BlockHash): Future[Option[BlockHeader]] {.async.} = 
  let
    contentKeyType = 
      ContentKeyType(chainId: chainId, blockHash: hash)
    contentKeyHeader = 
      ContentKey(contentType: blockHeader, blockHeaderKey: contentKeyType)
    (keyEncoded, contentId) = encodeKey(contentKeyHeader)
  
  let maybeHeaderContent = await h.getContent(keyEncoded, contentId)

  if maybeHeaderContent.isNone():
    return none(BlockHeader)
  
  let headerContent = maybeHeaderContent.unsafeGet()

  var rlp = rlpFromBytes(headerContent)
  let blockHeader = rlp.read(BlockHeader)
  
  if not (blockHeader.blockHash() == hash):
    # TODO: Header with different hash than expected maybe we should punish peer which sent
    # us this ? 
    return none(BlockHeader)
  
  if h.portalProtocol.inRange(contentId):
     h.contentDB.put(contentId, headerContent)

  return some(blockHeader)
  
proc getBlock*(h: HistoryNetwork, chainId: uint16, hash: BlockHash): Future[Option[Block]] {.async.} = 
  let maybeHeader = await h.getBlockHeader(chainId, hash)

  if maybeHeader.isNone():
    # we do not have header for given hash,so we would not be able to validate
    # that received body really belong it
    return none(Block)
  
  let header = maybeHeader.unsafeGet()

  let
    contentKeyType = 
      ContentKeyType(chainId: chainId, blockHash: hash)
    contentKeyBody = 
      ContentKey(contentType: blockBody, blockBodyKey: contentKeyType)
    (keyEncoded, contentId) = encodeKey(contentKeyBody)

  let maybeBodyContent = await h.getContent(keyEncoded, contentId)

  if maybeBodyContent.isNone():
    return none(Block)
  
  let bodyContent = maybeBodyContent.unsafeGet()

  var rlp = rlpFromBytes(bodyContent)
  let blockBody = rlp.read(BlockBody)
  
  let calculatedTxRoot = calcTxRoot(blockBody.transactions)
  let calculatedOmmersHash = rlpHash(blockBody.uncles)

  if header.txRoot != calculatedTxRoot or header.ommersHash != calculatedOmmersHash:
    # we got block body (bundle of transactions and uncles) which do not match 
    # header. For now just ignore it, but maybe we should penalize peer sending us such data?
    return none(Block)
  
  if h.portalProtocol.inRange(contentId):
     h.contentDB.put(contentId, bodyContent)

  return some[Block]((header, blockBody))

# TODO Add getRecepits call

proc new*(
    T: type HistoryNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    dataRadius = UInt256.high(),
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, historyProtocolId, contentDB, toContentIdHandler,
    dataRadius, bootstrapRecords,
    config = portalConfig)

  return HistoryNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(p: HistoryNetwork) =
  p.portalProtocol.start()

proc stop*(p: HistoryNetwork) =
  p.portalProtocol.stop()
