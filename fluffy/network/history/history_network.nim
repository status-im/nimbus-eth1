# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, sugar],
  stew/results, chronos, chronicles,
  eth/[common/eth_types, rlp],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../../../nimbus/utils,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  ./history_content

logScope:
  topics = "portal_hist"

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

func encodeKey(k: ContentKey): (ByteList, ContentId) =
  let keyEncoded = encode(k)
  return (keyEncoded, toContentId(keyEncoded))

func getEncodedKeyForContent(
    cType: ContentType, chainId: uint16, hash: BlockHash):
    (ByteList, ContentId) =
  let contentKeyType = ContentKeyType(chainId: chainId, blockHash: hash)

  let contentKey =
    case cType
    of blockHeader:
      ContentKey(contentType: cType, blockHeaderKey: contentKeyType)
    of blockBody:
      ContentKey(contentType: cType, blockBodyKey: contentKeyType)
    of receipts:
      ContentKey(contentType: cType, receiptsKey: contentKeyType)

  return encodeKey(contentKey)

proc validateHeaderBytes*(
    bytes: openArray[byte], hash: BlockHash): Option[BlockHeader] =
  try:
    var rlp = rlpFromBytes(bytes)

    let blockHeader = rlp.read(BlockHeader)

    if not (blockHeader.blockHash() == hash):
      # TODO: Header with different hash than expected, maybe we should punish
      # peer which sent us this ?
      return none(BlockHeader)

    return some(blockHeader)

  except MalformedRlpError, UnsupportedRlpError, RlpTypeMismatch:
    # TODO add some logging about failed decoding
    return none(BlockHeader)

proc validateBodyBytes*(
    bytes: openArray[byte], txRoot: KeccakHash, ommersHash: KeccakHash):
    Option[BlockBody] =
  try:
    var rlp = rlpFromBytes(bytes)

    let blockBody = rlp.read(BlockBody)

    let calculatedTxRoot = calcTxRoot(blockBody.transactions)
    let calculatedOmmersHash = rlpHash(blockBody.uncles)

    if txRoot != calculatedTxRoot or ommersHash != calculatedOmmersHash:
      # we got block body (bundle of transactions and uncles) which do not match
      # header. For now just ignore it, but maybe we should penalize peer
      # sending us such data?
      return none(BlockBody)

    return some(blockBody)

  except RlpError, MalformedRlpError, UnsupportedRlpError, RlpTypeMismatch:
    # TODO add some logging about failed decoding
    return none(BlockBody)

proc getContentFromDb(
    h: HistoryNetwork, T: type, contentId: ContentId): Option[T] =
  if h.portalProtocol.inRange(contentId):
    let contentFromDB = h.contentDB.get(contentId)
    if contentFromDB.isSome():
      var rlp = rlpFromBytes(contentFromDB.unsafeGet())
      try:
        let content = rlp.read(T)
        return some(content)
      except CatchableError as e:
        # Content in db should always have valid formatting, so this should not
        # happen
        raiseAssert(e.msg)
    else:
      return none(T)
  else:
    return none(T)

proc getBlockHeader*(
    h: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[BlockHeader]] {.async.} =
  let (keyEncoded, contentId) = getEncodedKeyForContent(blockHeader, chainId, hash)

  let maybeHeaderFromDb = h.getContentFromDb(BlockHeader, contentId)

  if maybeHeaderFromDb.isSome():
    info "Fetched block header from database", hash
    return maybeHeaderFromDb

  let maybeHeaderContent = await h.portalProtocol.contentLookup(keyEncoded, contentId)

  if maybeHeaderContent.isNone():
    warn "Failed fetching block header from the network", hash
    return none(BlockHeader)

  let headerContent = maybeHeaderContent.unsafeGet()

  let maybeHeader = validateHeaderBytes(headerContent.content, hash)

  if maybeHeader.isSome():
    info "Fetched block header from the network", hash
    # Content is valid we can propagate it to interested peers
    h.portalProtocol.triggerPoke(
      headerContent.nodesInterestedInContent,
      keyEncoded,
      headerContent.content
    )

    if h.portalProtocol.inRange(contentId):
      # content is valid and in our range, save it into our db
      # TODO handle radius adjustments
      discard h.contentDB.put(
                contentId, 
                headerContent.content,
                h.portalProtocol.localNode.id
              )

  return maybeHeader

proc getBlock*(
    h: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[Block]] {.async.} =
  let maybeHeader = await h.getBlockHeader(chainId, hash)

  if maybeHeader.isNone():
    # we do not have header for given hash,so we would not be able to validate
    # that received body really belong it
    return none(Block)

  let header = maybeHeader.unsafeGet()

  let (keyEncoded, contentId) = getEncodedKeyForContent(blockBody, chainId, hash)

  let maybeBodyFromDb = h.getContentFromDb(BlockBody, contentId)

  if maybeBodyFromDb.isSome():
    info "Fetched block body from database", hash
    return some[Block]((header, maybeBodyFromDb.unsafeGet()))

  let maybeBodyContent = await h.portalProtocol.contentLookup(keyEncoded, contentId)

  if maybeBodyContent.isNone():
    warn "Failed fetching block body from the network", hash
    return none(Block)

  let bodyContent = maybeBodyContent.unsafeGet()

  let maybeBody = validateBodyBytes(bodyContent.content, header.txRoot, header.ommersHash)

  if maybeBody.isNone():
    return none(Block)

  info "Fetched block body from the network", hash

  let blockBody = maybeBody.unsafeGet()

  # body is valid, propagate it to interested peers
  h.portalProtocol.triggerPoke(
    bodyContent.nodesInterestedInContent,
    keyEncoded,
    bodyContent.content
  )

  # content is in range and valid, put into db
  if h.portalProtocol.inRange(contentId):
    # TODO handle radius adjustments
    discard h.contentDB.put(
              contentId, bodyContent.content,
              h.portalProtocol.localNode.id
            )

  return some[Block]((header, blockBody))

proc validateContent(content: openArray[byte], contentKey: ByteList): bool =
  let keyOpt = contentKey.decode()

  if keyOpt.isNone():
    return false

  let key = keyOpt.get()

  case key.contentType:
  of blockHeader:
    validateHeaderBytes(content, key.blockHeaderKey.blockHash).isSome()
  of blockBody:
    true
    # TODO: Need to get the header from the db or the network for this. Or how
    # to deal with this?
  of receipts:
    true

proc new*(
    T: type HistoryNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    dataRadius = UInt256.high(),
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, historyProtocolId, contentDB,
    toContentIdHandler, validateContent,
    dataRadius, bootstrapRecords,
    config = portalConfig)

  return HistoryNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(p: HistoryNetwork) =
  info "Starting Portal execution history network",
    protocolId = p.portalProtocol.protocolId
  p.portalProtocol.start()

proc stop*(p: HistoryNetwork) =
  p.portalProtocol.stop()
