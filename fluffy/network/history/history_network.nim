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
    processContentLoop: Future[void]

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
      return err("Failed to decode block body: " & e.msg)

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
      return err("Failed to decode receipts: " & e.msg)

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
    n: HistoryNetwork, T: type, contentId: ContentId): Option[T] =
  if n.portalProtocol.inRange(contentId):
    n.contentDB.get(T, contentId)
  else:
    none(T)

## Public API to get the history network specific types, either from database
## or through a lookup on the Portal Network

const requestRetries = 4
# TODO: Currently doing 4 retries on lookups but only when the validation fails.
# This is to avoid nodes that provide garbage from blocking us with getting the
# requested data. Might want to also do that on a failed lookup, as perhaps this
# could occur when being really unlucky with nodes timing out on requests.
# Additionally, more improvements could be done with the lookup, as currently
# ongoing requests are cancelled after the receival of the first response,
# however that response is not yet validated at that moment.

proc getBlockHeader*(
    n: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[BlockHeader]] {.async.} =
  let (keyEncoded, contentId) =
    getEncodedKeyForContent(blockHeader, chainId, hash)

  let headerFromDb = n.getContentFromDb(BlockHeader, contentId)
  if headerFromDb.isSome():
    info "Fetched block header from database", hash
    return headerFromDb

  for i in 0..<requestRetries:
    let headerContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)
    if headerContentLookup.isNone():
      warn "Failed fetching block header from the network", hash
      return none(BlockHeader)

    let headerContent = headerContentLookup.unsafeGet()

    let res = validateBlockHeaderBytes(headerContent.content, hash)
    if res.isOk():
      info "Fetched block header from the network", hash
      # Content is valid we can propagate it to interested peers
      n.portalProtocol.triggerPoke(
        headerContent.nodesInterestedInContent,
        keyEncoded,
        headerContent.content
      )

      n.portalProtocol.storeContent(contentId, headerContent.content)

      return some(res.get())
    else:
      warn "Validation of block header failed", err = res.error, hash

  # Headers were requested `requestRetries` times and all failed on validation
  return none(BlockHeader)

proc getBlockBody*(
    n: HistoryNetwork, chainId: uint16, hash: BlockHash, header: BlockHeader):
    Future[Option[BlockBody]] {.async.} =

  # Got header with empty body, no need to make any db calls or network requests
  if header.txRoot == BLANK_ROOT_HASH and header.ommersHash == EMPTY_UNCLE_HASH:
    return some(BlockBody(transactions: @[], uncles: @[]))

  let
    (keyEncoded, contentId) = getEncodedKeyForContent(blockBody, chainId, hash)
    bodyFromDb = n.getContentFromDb(BlockBody, contentId)

  if bodyFromDb.isSome():
    info "Fetched block body from database", hash
    return bodyFromDb

  for i in 0..<requestRetries:
    let bodyContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)

    if bodyContentLookup.isNone():
      warn "Failed fetching block body from the network", hash
      # move to next loop iteration for next retry
      continue

    let bodyContent = bodyContentLookup.unsafeGet()

    let res = validateBlockBodyBytes(
      bodyContent.content, header.txRoot, header.ommersHash)
    if res.isOk():
      info "Fetched block body from the network", hash

      # body is valid, propagate it to interested peers
      n.portalProtocol.triggerPoke(
        bodyContent.nodesInterestedInContent,
        keyEncoded,
        bodyContent.content
      )

      n.portalProtocol.storeContent(contentId, bodyContent.content)

      return some(res.get())
    else:
      warn "Validation of block body failed", err = res.error, hash

  return none(BlockBody)

proc getBlock*(
    n: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[Block]] {.async.} =
  let headerOpt = await n.getBlockHeader(chainId, hash)
  if headerOpt.isNone():
    # Cannot validate block without header.
    return none(Block)

  let header = headerOpt.unsafeGet()

  let bodyOpt = await n.getBlockBody(chainId, hash, header)

  if bodyOpt.isNone():
    return none(Block)

  let body = bodyOpt.unsafeGet()

  return some((header, body))

proc getReceipts*(
    n: HistoryNetwork,
    chainId: uint16,
    hash: BlockHash,
    header: BlockHeader): Future[Option[seq[Receipt]]] {.async.} =
  if header.receiptRoot == BLANK_ROOT_HASH:
    # Short path for empty receipts indicated by receipts root
    return some(newSeq[Receipt]())

  let (keyEncoded, contentId) = getEncodedKeyForContent(receipts, chainId, hash)

  let receiptsFromDb = n.getContentFromDb(seq[Receipt], contentId)

  if receiptsFromDb.isSome():
    info "Fetched receipts from database", hash
    return receiptsFromDb

  for i in 0..<requestRetries:
    let receiptsContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)
    if receiptsContentLookup.isNone():
      warn "Failed fetching receipts from the network", hash
      return none(seq[Receipt])

    let receiptsContent = receiptsContentLookup.unsafeGet()

    let res = validateReceiptsBytes(receiptsContent.content, header.receiptRoot)
    if res.isOk():
      info "Fetched receipts from the network", hash

      let receipts = res.get()

      # receipts are valid, propagate it to interested peers
      n.portalProtocol.triggerPoke(
        receiptsContent.nodesInterestedInContent,
        keyEncoded,
        receiptsContent.content
      )

      n.portalProtocol.storeContent(contentId, receiptsContent.content)

      return some(res.get())
    else:
      warn "Validation of receipts failed", err = res.error, hash

  return none(seq[Receipt])

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

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKey: ByteList):
    Future[bool] {.async.} =
  let keyOpt = contentKey.decode()

  if keyOpt.isNone():
    return false

  let key = keyOpt.get()

  case key.contentType:
  of blockHeader:
    # TODO: Add validation based on accumulator data.
    return validateBlockHeaderBytes(content, key.blockHeaderKey.blockHash).isOk()
  of blockBody:
    let headerOpt = await n.getBlockHeader(
      key.blockBodyKey.chainId, key.blockBodyKey.blockHash)

    if headerOpt.isSome():
      let header = headerOpt.get()
      return validateBlockBodyBytes(content, header.txRoot, header.ommersHash).isOk()
    else:
      # Can't find the header, no way to validate the block body
      return false
  of receipts:
    let headerOpt = await n.getBlockHeader(
      key.receiptsKey.chainId, key.receiptsKey.blockHash)

    if headerOpt.isSome():
      let header = headerOpt.get()
      return validateReceiptsBytes(content, header.receiptRoot).isOk()
    else:
      # Can't find the header, no way to validate the receipts
      return false
  of epochAccumulator:
    # TODO: Add validation based on MasterAccumulator
    return validateEpochAccumulator(content)
  of masterAccumulator:
    return validateMasterAccumulator(content)

proc new*(
    T: type HistoryNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let portalProtocol = PortalProtocol.new(
    baseProtocol, historyProtocolId, contentDB,
    toContentIdHandler, bootstrapRecords,
    config = portalConfig)

  return HistoryNetwork(portalProtocol: portalProtocol, contentDB: contentDB)

proc processContentLoop(n: HistoryNetwork) {.async.} =
  try:
    while true:
      let (contentKeys, contentItems) =
        await n.portalProtocol.stream.contentQueue.popFirst()

      # content passed here can have less items then contentKeys, but not more.
      for i, contentItem in contentItems:
        let contentKey = contentKeys[i]
        if await n.validateContent(contentItem, contentKey):
          let contentIdOpt = n.portalProtocol.toContentId(contentKey)
          if contentIdOpt.isNone():
            continue

          let contentId = contentIdOpt.get()

          n.portalProtocol.storeContent(contentId, contentItem)

          info "Received valid offered content", contentKey
        else:
          error "Received invalid offered content", contentKey
          # On one invalid piece of content we drop all and don't forward any of it
          # TODO: Could also filter it out and still gossip the rest.
          continue

      asyncSpawn n.portalProtocol.neighborhoodGossip(contentKeys, contentItems)
  except CancelledError:
    trace "processContentLoop canceled"

proc start*(n: HistoryNetwork) =
  info "Starting Portal execution history network",
    protocolId = n.portalProtocol.protocolId
  n.portalProtocol.start()

  n.processContentLoop = processContentLoop(n)

proc stop*(n: HistoryNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancel()
