# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/options,
  stew/results, chronos, chronicles, nimcrypto/[keccak, hash],
  eth/[common/eth_types, rlp, trie, trie/db],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../../../nimbus/constants,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/[history_content, accumulator]

logScope:
  topics = "portal_hist"

const
  historyProtocolId* = [byte 0x50, 0x0B]

type
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB

  Block* = (BlockHeader, BlockBody)

func setStreamTransport*(n: HistoryNetwork, transport: UtpDiscv5Protocol) =
  setTransport(n.portalProtocol.stream, transport)

func toContentIdHandler(contentKey: ByteList): Option[ContentId] =
  some(toContentId(contentKey))

func encodeKey(k: ContentKey): (ByteList, ContentId) =
  let keyEncoded = encode(k)
  return (keyEncoded, toContentId(keyEncoded))

func getEncodedKeyForContent(
    cType: ContentType, chainId: uint16, hash: BlockHash):
    (ByteList, ContentId) =
  let contentKeyType = BlockKey(chainId: chainId, blockHash: hash)

  let contentKey =
    case cType
    of blockHeader:
      ContentKey(contentType: cType, blockHeaderKey: contentKeyType)
    of blockBody:
      ContentKey(contentType: cType, blockBodyKey: contentKeyType)
    of receipts:
      ContentKey(contentType: cType, receiptsKey: contentKeyType)
    of epochAccumulator:
      raiseAssert("Not implemented")
    of masterAccumulator:
      raiseAssert("Not implemented")

  return encodeKey(contentKey)

func decodeRlp*(bytes: openArray[byte], T: type): Result[T, string] =
  try:
    ok(rlp.decode(bytes, T))
  except RlpError as e:
    err(e.msg)

## Calls to go from SSZ decoded types to RLP fully decoded types

func fromPortalBlockBody(
    T: type BlockBody, body: BlockBodySSZ): Result[T, string] =
  ## Get the full decoded BlockBody from the SSZ-decoded `PortalBlockBody`.
  try:
    var transactions: seq[Transaction]
    for tx in body.transactions:
      transactions.add(rlp.decode(tx.asSeq(), Transaction))

    let uncles = rlp.decode(body.uncles.asSeq(), seq[BlockHeader])

    ok(BlockBody(transactions: transactions, uncles: uncles))
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

func fromReceipts(
    T: type seq[Receipt], receipts: ReceiptsSSZ): Result[T, string] =
  ## Get the full decoded seq[Receipt] from the SSZ-decoded `Receipts`.
  try:
    var res: seq[Receipt]
    for receipt in receipts:
      res.add(rlp.decode(receipt.asSeq(), Receipt))

    ok(res)
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

## Calls to encode Block types to the SSZ types.

func fromBlockBody(T: type BlockBodySSZ, body: BlockBody): T =
  var transactions: Transactions
  for tx in body.transactions:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  let uncles = Uncles(rlp.encode(body.uncles))

  BlockBodySSZ(transactions: transactions, uncles: uncles)

func fromReceipts(T: type ReceiptsSSZ, receipts: seq[Receipt]): T =
  var receiptsSSZ: ReceiptsSSZ
  for receipt in receipts:
    discard receiptsSSZ.add(ReceiptByteList(rlp.encode(receipt)))

  receiptsSSZ

func encode*(blockBody: BlockBody): seq[byte] =
  let portalBlockBody = BlockBodySSZ.fromBlockBody(blockBody)

  SSZ.encode(portalBlockBody)

func encode*(receipts: seq[Receipt]): seq[byte] =
  let portalReceipts = ReceiptsSSZ.fromReceipts(receipts)

  SSZ.encode(portalReceipts)

## Calls and helper calls to do validation of block header, body and receipts
# TODO: Failures on validation and perhaps deserialisation should be punished
# for if/when peer scoring/banning is added.

proc calcRootHash(items: Transactions | ReceiptsSSZ): Hash256 =
  var tr = initHexaryTrie(newMemoryDB())
  for i, t in items:
    try:
      tr.put(rlp.encode(i), t.asSeq())
    except RlpError as e:
      # TODO: Investigate this RlpError as it doesn't sound like this is
      # something that can actually occur.
      raiseAssert(e.msg)

  return tr.rootHash

template calcTxsRoot*(transactions: Transactions): Hash256 =
  calcRootHash(transactions)

template calcReceiptsRoot*(receipts: ReceiptsSSZ): Hash256 =
  calcRootHash(receipts)

func validateBlockHeaderBytes*(
    bytes: openArray[byte], hash: BlockHash): Result[BlockHeader, string] =

  let header = ? decodeRlp(bytes, BlockHeader)

  if not (header.blockHash() == hash):
    err("Block header hash does not match")
  else:
    ok(header)

proc validateBlockBody(
    body: BlockBodySSZ, txsRoot, ommersHash: KeccakHash):
    Result[void, string] =
  ## Validate the block body against the txRoot amd ommersHash from the header.
  let calculatedOmmersHash = keccak256.digest(body.uncles.asSeq())
  if calculatedOmmersHash != ommersHash:
    return err("Invalid ommers hash")

  let calculatedTxsRoot = calcTxsRoot(body.transactions)
  if calculatedTxsRoot != txsRoot:
    return err("Invalid transactions root")

  ok()

proc validateBlockBodyBytes*(
    bytes: openArray[byte], txRoot, ommersHash: KeccakHash):
    Result[BlockBody, string] =
  ## Fully decode the SSZ Block Body and validate it against the header.
  let body =
    try:
      SSZ.decode(bytes, BlockBodySSZ)
    except SszError as e:
      return err("Failed to decode block body" & e.msg)

  ? validateBlockBody(body, txRoot, ommersHash)

  BlockBody.fromPortalBlockBody(body)

proc validateReceipts(
    receipts: ReceiptsSSZ, receiptsRoot: KeccakHash): Result[void, string] =
  let calculatedReceiptsRoot = calcReceiptsRoot(receipts)

  if calculatedReceiptsRoot != receiptsRoot:
    return err("Unexpected receipt root")
  else:
    return ok()

proc validateReceiptsBytes*(
    bytes: openArray[byte],
    receiptsRoot: KeccakHash): Result[seq[Receipt], string] =
  ## Fully decode the SSZ Block Body and validate it against the header.
  let receipts =
    try:
      SSZ.decode(bytes, ReceiptsSSZ)
    except SszError as e:
      return err("Failed to decode receipts" & e.msg)

  ? validateReceipts(receipts, receiptsRoot)

  seq[Receipt].fromReceipts(receipts)

## ContentDB getters for specific history network types

proc getSszDecoded(
    db: ContentDB, contentId: ContentID,
    T: type auto): Option[T] =
  let res = db.get(contentId)
  if res.isSome():
    try:
      some(SSZ.decode(res.get(), T))
    except SszError as e:
      raiseAssert("Stored data should always be serialized correctly: " & e.msg)
  else:
    none(T)

proc get(db: ContentDB, T: type BlockHeader, contentId: ContentID): Option[T] =
  let contentFromDB = db.get(contentId)
  if contentFromDB.isSome():
    let res = decodeRlp(contentFromDB.get(), T)
    if res.isErr():
      raiseAssert(res.error)
    else:
      some(res.get())
  else:
    none(T)

proc get(db: ContentDB, T: type BlockBody, contentId: ContentID): Option[T] =
  let contentFromDB = db.getSszDecoded(contentId, BlockBodySSZ)
  if contentFromDB.isSome():
    let res = T.fromPortalBlockBody(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      some(res.get())
  else:
    none(T)

proc get(db: ContentDB, T: type seq[Receipt], contentId: ContentID): Option[T] =
  let contentFromDB = db.getSszDecoded(contentId, ReceiptsSSZ)
  if contentFromDB.isSome():
    let res = T.fromReceipts(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      some(res.get())
  else:
    none(T)

proc getContentFromDb(
    h: HistoryNetwork, T: type, contentId: ContentId): Option[T] =
  if h.portalProtocol.inRange(contentId):
    h.contentDB.get(T, contentId)
  else:
    none(T)

## Public API to get the history network specific types, either from database
## or through a lookup on the Portal Network

proc getBlockHeader*(
    h: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[BlockHeader]] {.async.} =
  let (keyEncoded, contentId) =
    getEncodedKeyForContent(blockHeader, chainId, hash)

  let headerFromDb = h.getContentFromDb(BlockHeader, contentId)
  if headerFromDb.isSome():
    info "Fetched block header from database", hash
    return headerFromDb

  let headerContentLookup =
    await h.portalProtocol.contentLookup(keyEncoded, contentId)
  if headerContentLookup.isNone():
    warn "Failed fetching block header from the network", hash
    return none(BlockHeader)

  let headerContent = headerContentLookup.unsafeGet()

  let res = validateBlockHeaderBytes(headerContent.content, hash)
  # TODO: If the validation fails, a new request could be done.
  if res.isOk():
    info "Fetched block header from the network", hash
    # Content is valid we can propagate it to interested peers
    h.portalProtocol.triggerPoke(
      headerContent.nodesInterestedInContent,
      keyEncoded,
      headerContent.content
    )

    h.portalProtocol.storeContent(contentId, headerContent.content)

    return some(res.get())
  else:
    return none(BlockHeader)

proc getBlockBody*(
    h: HistoryNetwork,
    chainId: uint16,
    hash: BlockHash,
    header: BlockHeader):Future[Option[BlockBody]] {.async.} =
  let
    (keyEncoded, contentId) = getEncodedKeyForContent(blockBody, chainId, hash)
    bodyFromDb = h.getContentFromDb(BlockBody, contentId)

  if bodyFromDb.isSome():
    info "Fetched block body from database", hash
    return some(bodyFromDb.unsafeGet())

  let bodyContentLookup =
    await h.portalProtocol.contentLookup(keyEncoded, contentId)
  if bodyContentLookup.isNone():
    warn "Failed fetching block body from the network", hash
    return none(BlockBody)

  let bodyContent = bodyContentLookup.unsafeGet()

  let res = validateBlockBodyBytes(
    bodyContent.content, header.txRoot, header.ommersHash)
  if res.isErr():
    return none(BlockBody)

  info "Fetched block body from the network", hash

  let blockBody = res.get()

  # body is valid, propagate it to interested peers
  h.portalProtocol.triggerPoke(
    bodyContent.nodesInterestedInContent,
    keyEncoded,
    bodyContent.content
  )

  h.portalProtocol.storeContent(contentId, bodyContent.content)

  return some(blockBody)

proc getBlock*(
    h: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[Block]] {.async.} =
  let headerOpt = await h.getBlockHeader(chainId, hash)
  if headerOpt.isNone():
    # Cannot validate block without header.
    return none(Block)

  let header = headerOpt.unsafeGet()

  let bodyOpt = await h.getBlockBody(chainId, hash, header)

  if bodyOpt.isNone():
    return none(Block)

  let body = bodyOpt.unsafeGet()

  return some[Block]((header, body))

proc getReceipts*(
    h: HistoryNetwork,
    chainId: uint16,
    hash: BlockHash,
    header: BlockHeader): Future[Option[seq[Receipt]]] {.async.} =
  if header.receiptRoot == BLANK_ROOT_HASH:
    # The header has no receipts, return early with empty receipts
    return some(newSeq[Receipt]())

  let (keyEncoded, contentId) = getEncodedKeyForContent(receipts, chainId, hash)

  let receiptsFromDb = h.getContentFromDb(seq[Receipt], contentId)

  if receiptsFromDb.isSome():
    info "Fetched receipts from database", hash
    return some(receiptsFromDb.unsafeGet())

  let receiptsContentLookup =
    await h.portalProtocol.contentLookup(keyEncoded, contentId)
  if receiptsContentLookup.isNone():
    warn "Failed fetching receipts from the network", hash
    return none[seq[Receipt]]()

  let receiptsContent = receiptsContentLookup.unsafeGet()

  let res = validateReceiptsBytes(receiptsContent.content, header.receiptRoot)
  if res.isErr():
    return none[seq[Receipt]]()

  info "Fetched receipts from the network", hash

  let receipts = res.get()

  # receips are valid, propagate it to interested peers
  h.portalProtocol.triggerPoke(
    receiptsContent.nodesInterestedInContent,
    keyEncoded,
    receiptsContent.content
  )

  h.portalProtocol.storeContent(contentId, receiptsContent.content)

  return some(receipts)

func validateEpochAccumulator(bytes: openArray[byte]): bool =
  # For now just validate by checking if de-serialization works
  try:
    discard SSZ.decode(bytes, EpochAccumulator)
    true
  except SszError:
    false

func validateMasterAccumulator(bytes: openArray[byte]): bool =
  # For now just validate by checking if de-serialization works
  try:
    discard SSZ.decode(bytes, Accumulator)
    true
  except SszError:
    false

proc validateContent(content: openArray[byte], contentKey: ByteList): bool =
  let keyOpt = contentKey.decode()

  if keyOpt.isNone():
    return false

  let key = keyOpt.get()

  case key.contentType:
  of blockHeader:
    validateBlockHeaderBytes(content, key.blockHeaderKey.blockHash).isOk()
  of blockBody:
    true
    # TODO: Need to get the header from the db or the network for this. Or how
    # to deal with this?
  of receipts:
    true
  of epochAccumulator:
    validateEpochAccumulator(content)
  of masterAccumulator:
    validateMasterAccumulator(content)

proc new*(
    T: type HistoryNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, historyProtocolId, contentDB,
    toContentIdHandler, validateContent, bootstrapRecords,
    config = portalConfig)

  return HistoryNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc start*(p: HistoryNetwork) =
  info "Starting Portal execution history network",
    protocolId = p.portalProtocol.protocolId
  p.portalProtocol.start()

proc stop*(p: HistoryNetwork) =
  p.portalProtocol.stop()
