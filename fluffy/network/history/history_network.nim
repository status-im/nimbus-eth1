# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, tables],
  stew/results, chronos, chronicles,
  eth/[common/eth_types_rlp, rlp, trie, trie/db],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../../../nimbus/constants,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/[history_content, accumulator]

logScope:
  topics = "portal_hist"

export accumulator

const
  historyProtocolId* = [byte 0x50, 0x0B]

type
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(ContentKeysList, seq[seq[byte]])]
    accumulator*: FinishedAccumulator
    processContentLoop: Future[void]

  Block* = (BlockHeader, BlockBody)

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

func encodeKey(k: ContentKey): (ByteList, ContentId) =
  let keyEncoded = encode(k)
  return (keyEncoded, toContentId(keyEncoded))

func getEncodedKeyForContent(
    cType: ContentType, hash: BlockHash):
    (ByteList, ContentId) =
  let contentKeyType = BlockKey(blockHash: hash)

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
    of blockHeaderWithProof:
      ContentKey(contentType: cType, blockHeaderWithProofKey: contentKeyType)

  return encodeKey(contentKey)

func decodeRlp*(input: openArray[byte], T: type): Result[T, string] =
  try:
    ok(rlp.decode(input, T))
  except RlpError as e:
    err(e.msg)

func decodeSsz*(input: openArray[byte], T: type): Result[T, string] =
  try:
    ok(SSZ.decode(input, T))
  except SszError as e:
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

  if header.withdrawalsRoot.isSome:
    return err("Withdrawals not yet implemented")

  if not (header.blockHash() == hash):
    err("Block header hash does not match")
  else:
    ok(header)

proc validateBlockBody(
    body: BlockBodySSZ, txsRoot, ommersHash: KeccakHash):
    Result[void, string] =
  ## Validate the block body against the txRoot amd ommersHash from the header.
  let calculatedOmmersHash = keccakHash(body.uncles.asSeq())
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
  let body = ? decodeSsz(bytes, BlockBodySSZ)

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
  let receipts = ? decodeSsz(bytes, ReceiptsSSZ)

  ? validateReceipts(receipts, receiptsRoot)

  seq[Receipt].fromReceipts(receipts)

## ContentDB helper calls for specific history network types

proc get(db: ContentDB, T: type BlockHeader, contentId: ContentId): Option[T] =
  let contentFromDB = db.get(contentId)
  if contentFromDB.isSome():
    let headerWithProof =
      try:
        SSZ.decode(contentFromDB.get(), BlockHeaderWithProof)
      except SszError as e:
        raiseAssert(e.msg)

    let res = decodeRlp(headerWithProof.header.asSeq(), T)
    if res.isErr():
      raiseAssert(res.error)
    else:
      some(res.get())
  else:
    none(T)

proc get(db: ContentDB, T: type BlockBody, contentId: ContentId): Option[T] =
  let contentFromDB = db.getSszDecoded(contentId, BlockBodySSZ)
  if contentFromDB.isSome():
    let res = T.fromPortalBlockBody(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      some(res.get())
  else:
    none(T)

proc get(db: ContentDB, T: type seq[Receipt], contentId: ContentId): Option[T] =
  let contentFromDB = db.getSszDecoded(contentId, ReceiptsSSZ)
  if contentFromDB.isSome():
    let res = T.fromReceipts(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      some(res.get())
  else:
    none(T)

proc get(
    db: ContentDB, T: type EpochAccumulator, contentId: ContentId): Option[T] =
  db.getSszDecoded(contentId, T)

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

func verifyHeader(
    n: HistoryNetwork, header: BlockHeader, proof: BlockHeaderProof):
    Result[void, string] =
  verifyHeader(n.accumulator, header, proof)

proc getVerifiedBlockHeader*(
    n: HistoryNetwork, hash: BlockHash):
    Future[Option[BlockHeader]] {.async.} =
  let (keyEncoded, contentId) =
    getEncodedKeyForContent(blockHeaderWithProof, hash)

  # Note: This still requests a BlockHeaderWithProof from the database, as that
  # is what is stored. But the proof doesn't need to be checked as everthing
  # should get checked before storing.
  let headerFromDb = n.getContentFromDb(BlockHeader, contentId)

  if headerFromDb.isSome():
    info "Fetched block header from database", hash, contentKey = keyEncoded
    return headerFromDb

  for i in 0..<requestRetries:
    let headerContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)
    if headerContentLookup.isNone():
      warn "Failed fetching block header with proof from the network",
        hash, contentKey = keyEncoded
      return none(BlockHeader)

    let headerContent = headerContentLookup.unsafeGet()

    let headerWithProofRes = decodeSsz(headerContent.content, BlockHeaderWithProof)
    if headerWithProofRes.isErr():
      warn "Failed decoding header with proof", err = headerWithProofRes.error
      return none(BlockHeader)

    let headerWithProof = headerWithProofRes.get()

    let res = validateBlockHeaderBytes(headerWithProof.header.asSeq(), hash)
    if res.isOk():
      let isCanonical = n.verifyHeader(res.get(), headerWithProof.proof)

      if isCanonical.isOk():
        info "Fetched block header from the network", hash, contentKey = keyEncoded
        # Content is valid, it can be propagated to interested peers
        n.portalProtocol.triggerPoke(
          headerContent.nodesInterestedInContent,
          keyEncoded,
          headerContent.content
        )

        n.portalProtocol.storeContent(keyEncoded, contentId, headerContent.content)

        return some(res.get())
    else:
      warn "Validation of block header failed", err = res.error, hash, contentKey = keyEncoded

  # Headers were requested `requestRetries` times and all failed on validation
  return none(BlockHeader)

# TODO: To be deprecated or not? Should there be the case for requesting a
# block header without proofs?
proc getBlockHeader*(
    n: HistoryNetwork, hash: BlockHash):
    Future[Option[BlockHeader]] {.async.} =
  let (keyEncoded, contentId) =
    getEncodedKeyForContent(blockHeader, hash)

  let headerFromDb = n.getContentFromDb(BlockHeader, contentId)
  if headerFromDb.isSome():
    info "Fetched block header from database", hash, contentKey = keyEncoded
    return headerFromDb

  for i in 0..<requestRetries:
    let headerContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)
    if headerContentLookup.isNone():
      warn "Failed fetching block header from the network", hash, contentKey = keyEncoded
      return none(BlockHeader)

    let headerContent = headerContentLookup.unsafeGet()

    let res = validateBlockHeaderBytes(headerContent.content, hash)
    if res.isOk():
      info "Fetched block header from the network", hash, contentKey = keyEncoded
      # Content is valid we can propagate it to interested peers
      n.portalProtocol.triggerPoke(
        headerContent.nodesInterestedInContent,
        keyEncoded,
        headerContent.content
      )

      n.portalProtocol.storeContent(keyEncoded, contentId, headerContent.content)

      return some(res.get())
    else:
      warn "Validation of block header failed", err = res.error, hash, contentKey = keyEncoded

  # Headers were requested `requestRetries` times and all failed on validation
  return none(BlockHeader)

proc getBlockBody*(
    n: HistoryNetwork, hash: BlockHash, header: BlockHeader):
    Future[Option[BlockBody]] {.async.} =

  # Got header with empty body, no need to make any db calls or network requests
  if header.txRoot == EMPTY_ROOT_HASH and header.ommersHash == EMPTY_UNCLE_HASH:
    return some(BlockBody(transactions: @[], uncles: @[]))

  let
    (keyEncoded, contentId) = getEncodedKeyForContent(blockBody, hash)
    bodyFromDb = n.getContentFromDb(BlockBody, contentId)

  if bodyFromDb.isSome():
    info "Fetched block body from database", hash, contentKey = keyEncoded
    return bodyFromDb

  for i in 0..<requestRetries:
    let bodyContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)

    if bodyContentLookup.isNone():
      warn "Failed fetching block body from the network", hash, contentKey = keyEncoded
      return none(BlockBody)

    let bodyContent = bodyContentLookup.unsafeGet()

    let res = validateBlockBodyBytes(
      bodyContent.content, header.txRoot, header.ommersHash)
    if res.isOk():
      info "Fetched block body from the network", hash, contentKey = keyEncoded

      # body is valid, propagate it to interested peers
      n.portalProtocol.triggerPoke(
        bodyContent.nodesInterestedInContent,
        keyEncoded,
        bodyContent.content
      )

      n.portalProtocol.storeContent(keyEncoded, contentId, bodyContent.content)

      return some(res.get())
    else:
      warn "Validation of block body failed", err = res.error, hash, contentKey = keyEncoded

  return none(BlockBody)

proc getBlock*(
    n: HistoryNetwork, hash: BlockHash):
    Future[Option[Block]] {.async.} =
  debug "Trying to retrieve block with hash", hash

  # Note: Using `getVerifiedBlockHeader` instead of getBlockHeader even though
  # proofs are not necessiarly needed, in order to avoid having to inject
  # also the original type into the network.
  let headerOpt = await n.getVerifiedBlockHeader(hash)
  if headerOpt.isNone():
    warn "Failed to get header when getting block with hash", hash
    # Cannot validate block without header.
    return none(Block)

  let header = headerOpt.unsafeGet()

  let bodyOpt = await n.getBlockBody(hash, header)

  if bodyOpt.isNone():
    warn "Failed to get body when gettin block with hash", hash
    return none(Block)

  let body = bodyOpt.unsafeGet()

  return some((header, body))

proc getReceipts*(
    n: HistoryNetwork,
    hash: BlockHash,
    header: BlockHeader): Future[Option[seq[Receipt]]] {.async.} =
  if header.receiptRoot == EMPTY_ROOT_HASH:
    # Short path for empty receipts indicated by receipts root
    return some(newSeq[Receipt]())

  let (keyEncoded, contentId) = getEncodedKeyForContent(receipts, hash)

  let receiptsFromDb = n.getContentFromDb(seq[Receipt], contentId)

  if receiptsFromDb.isSome():
    info "Fetched receipts from database", hash
    return receiptsFromDb

  for i in 0..<requestRetries:
    let receiptsContentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)
    if receiptsContentLookup.isNone():
      warn "Failed fetching receipts from the network", hash, contentKey = keyEncoded
      return none(seq[Receipt])

    let receiptsContent = receiptsContentLookup.unsafeGet()

    let res = validateReceiptsBytes(receiptsContent.content, header.receiptRoot)
    if res.isOk():
      info "Fetched receipts from the network", hash, contentKey = keyEncoded

      let receipts = res.get()

      # receipts are valid, propagate it to interested peers
      n.portalProtocol.triggerPoke(
        receiptsContent.nodesInterestedInContent,
        keyEncoded,
        receiptsContent.content
      )

      n.portalProtocol.storeContent(keyEncoded, contentId, receiptsContent.content)

      return some(res.get())
    else:
      warn "Validation of receipts failed", err = res.error, hash, contentKey = keyEncoded

  return none(seq[Receipt])

proc getEpochAccumulator(
    n: HistoryNetwork, epochHash: Digest):
    Future[Option[EpochAccumulator]] {.async.} =
  let
    contentKey = ContentKey(
      contentType: epochAccumulator,
      epochAccumulatorKey: EpochAccumulatorKey(epochHash: epochHash))

    keyEncoded = encode(contentKey)
    contentId = toContentId(keyEncoded)

    accumulatorFromDb = n.getContentFromDb(EpochAccumulator, contentId)

  if accumulatorFromDb.isSome():
    info "Fetched epoch accumulator from database", epochHash
    return accumulatorFromDb

  for i in 0..<requestRetries:
    let contentLookup =
      await n.portalProtocol.contentLookup(keyEncoded, contentId)
    if contentLookup.isNone():
      warn "Failed fetching epoch accumulator from the network", epochHash
      return none(EpochAccumulator)

    let accumulatorContent = contentLookup.unsafeGet()

    let epochAccumulator =
      try:
        SSZ.decode(accumulatorContent.content, EpochAccumulator)
      except SszError:
        continue
        # return none(EpochAccumulator)

    let hash = hash_tree_root(epochAccumulator)
    if hash == epochHash:
      info "Fetched epoch accumulator from the network", epochHash

      n.portalProtocol.triggerPoke(
        accumulatorContent.nodesInterestedInContent,
        keyEncoded,
        accumulatorContent.content
      )

      n.portalProtocol.storeContent(keyEncoded, contentId, accumulatorContent.content)

      return some(epochAccumulator)
    else:
      warn "Validation of epoch accumulator failed",
        hash, expectedHash = epochHash

  return none(EpochAccumulator)

proc getBlock*(
    n: HistoryNetwork, bn: UInt256):
    Future[Result[Option[Block], string]] {.async.} =
  let epochDataRes = n.accumulator.getBlockEpochDataForBlockNumber(bn)
  if epochDataRes.isOk():
    let
      epochData = epochDataRes.get()
      digest = Digest(data: epochData.epochHash)

      epochOpt = await n.getEpochAccumulator(digest)
    if epochOpt.isNone():
      return err("Cannot retrieve epoch accumulator for given block number")

    let
      epoch = epochOpt.unsafeGet()
      blockHash = epoch[epochData.blockRelativeIndex].blockHash

    let maybeBlock = await n.getBlock(blockHash)

    return ok(maybeBlock)
  else:
    return err(epochDataRes.error)

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKey: ByteList):
    Future[bool] {.async.} =
  let keyOpt = contentKey.decode()

  if keyOpt.isNone():
    return false

  let key = keyOpt.get()

  case key.contentType:
  of blockHeader:
    # Note: For now we still accept regular block header type to remain
    # compatible with the current specs. However, a verification is done by
    # basically requesting the header with proofs from somewhere else.
    # This all doesn't make much sense aside from compatibility and should
    # eventually be removed.
    let validateResult =
      validateBlockHeaderBytes(content, key.blockHeaderKey.blockHash)
    if validateResult.isErr():
      warn "Invalid block header offered", error = validateResult.error
      return false

    let header = validateResult.get()

    let res = await n.getVerifiedBlockHeader(key.blockHeaderKey.blockHash)
    if res.isNone():
      warn "Block header failed canonical verification"
      return false
    else:
      return true

  of blockBody:
    let res = await n.getVerifiedBlockHeader(key.blockBodyKey.blockHash)
    if res.isNone():
      warn "Block body Failed canonical verification"
      return false

    let header = res.get()
    let validationResult =
      validateBlockBodyBytes(content, header.txRoot, header.ommersHash)

    if validationResult.isErr():
      warn "Failed validating block body", error = validationResult.error
      return false
    else:
      return true

  of receipts:
    let res = await n.getVerifiedBlockHeader(key.receiptsKey.blockHash)
    if res.isNone():
      warn "Receipts failed canonical verification"
      return false

    let header = res.get()
    let validationResult =
      validateReceiptsBytes(content, header.receiptRoot)

    if validationResult.isErr():
      warn "Failed validating receipts", error = validationResult.error
      return false
    else:
      return true

  of epochAccumulator:
    # Check first if epochHash is part of master accumulator
    let epochHash = key.epochAccumulatorKey.epochHash
    if not n.accumulator.historicalEpochs.contains(epochHash.data):
      warn "Offered epoch accumulator is not part of master accumulator",
        epochHash
      return false

    let epochAccumulator =
      try:
        SSZ.decode(content, EpochAccumulator)
      except SszError:
        warn "Failed decoding epoch accumulator"
        return false

    # Next check the hash tree root, as this is probably more expensive
    let hash = hash_tree_root(epochAccumulator)
    if hash != epochHash:
      warn "Epoch accumulator has invalid root hash"
      return false
    else:
      return true

  of blockHeaderWithProof:
    let headerWithProofRes = decodeSsz(content, BlockHeaderWithProof)
    if headerWithProofRes.isErr():
      warn "Failed decoding header with proof", err = headerWithProofRes.error
      return false

    let headerWithProof = headerWithProofRes.get()

    let validateResult = validateBlockHeaderBytes(
      headerWithProof.header.asSeq(), key.blockHeaderWithProofKey.blockHash)
    if validateResult.isErr():
      warn "Invalid block header offered", error = validateResult.error
      return false

    let header = validateResult.get()

    let isCanonical = n.verifyHeader(header, headerWithProof.proof)
    if isCanonical.isErr():
      warn "Failed on check if header is part of canonical chain",
        error = isCanonical.error
      return false
    else:
      return true

proc new*(
    T: type HistoryNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    accumulator: FinishedAccumulator,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =
  let
    contentQueue = newAsyncQueue[(ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    portalProtocol = PortalProtocol.new(
      baseProtocol, historyProtocolId,
      toContentIdHandler, createGetHandler(contentDB), stream, bootstrapRecords,
      config = portalConfig)

  portalProtocol.dbPut = createStoreHandler(contentDB, portalConfig.radiusConfig, portalProtocol)

  HistoryNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: contentQueue,
    accumulator: accumulator
  )

proc validateContent(
    n: HistoryNetwork,
    contentKeys: ContentKeysList,
    contentItems: seq[seq[byte]]): Future[bool] {.async.} =
  # content passed here can have less items then contentKeys, but not more.
  for i, contentItem in contentItems:
    let contentKey = contentKeys[i]
    if await n.validateContent(contentItem, contentKey):
      let contentIdOpt = n.portalProtocol.toContentId(contentKey)
      if contentIdOpt.isNone():
        error "Received offered content with invalid content key", contentKey
        return false

      let contentId = contentIdOpt.get()

      n.portalProtocol.storeContent(contentKey, contentId, contentItem)

      info "Received offered content validated successfully", contentKey

    else:
      error "Received offered content failed validation", contentKey
      return false

  return true

proc neighborhoodGossipDiscardPeers(
    p: PortalProtocol,
    contentKeys: ContentKeysList,
    content: seq[seq[byte]]): Future[void] {.async.} =
  discard await p.neighborhoodGossip(contentKeys, content)

proc processContentLoop(n: HistoryNetwork) {.async.} =
  try:
    while true:
      let (contentKeys, contentItems) =
        await n.contentQueue.popFirst()

      # When there is one invalid content item, all other content items are
      # dropped and not gossiped around.
      # TODO: Differentiate between failures due to invalid data and failures
      # due to missing network data for validation.
      if await n.validateContent(contentKeys, contentItems):
        asyncSpawn n.portalProtocol.neighborhoodGossipDiscardPeers(
          contentKeys, contentItems
        )

  except CancelledError:
    trace "processContentLoop canceled"

proc start*(n: HistoryNetwork) =
  info "Starting Portal execution history network",
    protocolId = n.portalProtocol.protocolId,
    accumulatorRoot = hash_tree_root(n.accumulator)
  n.portalProtocol.start()

  n.processContentLoop = processContentLoop(n)

proc stop*(n: HistoryNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancel()
