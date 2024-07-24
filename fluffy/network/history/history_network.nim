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
  eth/[common/eth_types_rlp, rlp, trie, trie/db],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../common/common_types,
  ../../database/content_db,
  ../../network_metadata,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/[history_content, accumulator, beacon_chain_historical_roots]

logScope:
  topics = "portal_hist"

export accumulator

type
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])]
    accumulator*: FinishedAccumulator
    historicalRoots*: HistoricalRoots
    processContentLoop: Future[void]
    statusLogLoop: Future[void]

  Block* = (BlockHeader, BlockBody)

func toContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

## Calls to go from SSZ decoded Portal types to RLP fully decoded EL types

func fromPortalBlockBody*(
    T: type BlockBody, body: PortalBlockBodyLegacy
): Result[T, string] =
  ## Get the EL BlockBody from the SSZ-decoded `PortalBlockBodyLegacy`.
  try:
    var transactions: seq[Transaction]
    for tx in body.transactions:
      transactions.add(rlp.decode(tx.asSeq(), Transaction))

    let uncles = rlp.decode(body.uncles.asSeq(), seq[BlockHeader])

    ok(BlockBody(transactions: transactions, uncles: uncles))
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

func fromPortalBlockBody*(
    T: type BlockBody, body: PortalBlockBodyShanghai
): Result[T, string] =
  ## Get the EL BlockBody from the SSZ-decoded `PortalBlockBodyShanghai`.
  try:
    var transactions: seq[Transaction]
    for tx in body.transactions:
      transactions.add(rlp.decode(tx.asSeq(), Transaction))

    var withdrawals: seq[Withdrawal]
    for w in body.withdrawals:
      withdrawals.add(rlp.decode(w.asSeq(), Withdrawal))

    ok(
      BlockBody(
        transactions: transactions,
        uncles: @[], # Uncles must be empty, this is verified in `validateBlockBody`
        withdrawals: Opt.some(withdrawals),
      )
    )
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

func fromPortalBlockBodyOrRaise*(
    T: type BlockBody, body: PortalBlockBodyLegacy | PortalBlockBodyShanghai
): T =
  ## Get the EL BlockBody from one of the SSZ-decoded Portal BlockBody types.
  ## Will raise Assertion in case of invalid RLP encodings. Only use of data
  ## has been validated before!
  let res = BlockBody.fromPortalBlockBody(body)
  if res.isOk():
    res.get()
  else:
    raiseAssert(res.error)

func fromPortalReceipts*(
    T: type seq[Receipt], receipts: PortalReceipts
): Result[T, string] =
  ## Get the full decoded EL seq[Receipt] from the SSZ-decoded `PortalReceipts`.
  try:
    var res: seq[Receipt]
    for receipt in receipts:
      res.add(rlp.decode(receipt.asSeq(), Receipt))

    ok(res)
  except RlpError as e:
    err("RLP decoding failed: " & e.msg)

## Calls to encode EL block types to the SSZ encoded Portal types.

# TODO: The fact that we have different Portal BlockBody types for the different
# forks but not for the EL BlockBody (usage of Option) does not play so well
# together.

func fromBlockBody*(T: type PortalBlockBodyLegacy, body: BlockBody): T =
  var transactions: Transactions
  for tx in body.transactions:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  let uncles = Uncles(rlp.encode(body.uncles))

  PortalBlockBodyLegacy(transactions: transactions, uncles: uncles)

func fromBlockBody*(T: type PortalBlockBodyShanghai, body: BlockBody): T =
  var transactions: Transactions
  for tx in body.transactions:
    discard transactions.add(TransactionByteList(rlp.encode(tx)))

  let uncles = Uncles(rlp.encode(body.uncles))

  doAssert(body.withdrawals.isSome())

  var withdrawals: Withdrawals
  for w in body.withdrawals.get():
    discard withdrawals.add(WithdrawalByteList(rlp.encode(w)))
  PortalBlockBodyShanghai(
    transactions: transactions, uncles: uncles, withdrawals: withdrawals
  )

func fromReceipts*(T: type PortalReceipts, receipts: seq[Receipt]): T =
  var portalReceipts: PortalReceipts
  for receipt in receipts:
    discard portalReceipts.add(ReceiptByteList(rlp.encode(receipt)))

  portalReceipts

func encode*(blockBody: BlockBody): seq[byte] =
  if blockBody.withdrawals.isSome():
    SSZ.encode(PortalBlockBodyShanghai.fromBlockBody(blockBody))
  else:
    SSZ.encode(PortalBlockBodyLegacy.fromBlockBody(blockBody))

func encode*(receipts: seq[Receipt]): seq[byte] =
  let portalReceipts = PortalReceipts.fromReceipts(receipts)

  SSZ.encode(portalReceipts)

## Calls and helper calls to do validation of block header, body and receipts
# TODO: Failures on validation and perhaps deserialisation should be punished
# for if/when peer scoring/banning is added.

proc calcRootHash(items: Transactions | PortalReceipts | Withdrawals): Hash256 =
  var tr = initHexaryTrie(newMemoryDB(), isPruning = false)
  for i, item in items:
    try:
      tr.put(rlp.encode(i.uint), item.asSeq())
    except RlpError as e:
      # RlpError should not occur
      # TODO: trace down why it might raise this
      raiseAssert(e.msg)

  return tr.rootHash

template calcTxsRoot*(transactions: Transactions): Hash256 =
  calcRootHash(transactions)

template calcReceiptsRoot*(receipts: PortalReceipts): Hash256 =
  calcRootHash(receipts)

template calcWithdrawalsRoot*(receipts: Withdrawals): Hash256 =
  calcRootHash(receipts)

func validateBlockHeaderBytes*(
    bytes: openArray[byte], hash: BlockHash
): Result[BlockHeader, string] =
  let header = ?decodeRlp(bytes, BlockHeader)

  # Note:
  # One could do additional quick-checks here such as timestamp vs the optional
  # (later forks) added fields. E.g. Shanghai field, Cancun fields,
  # zero ommersHash, etc.
  # However, the block hash comparison will obviously catch these and it is
  # pretty trivial to provide a non-canonical valid header.
  # It might be somewhat more useful if just done (temporarily) for the headers
  # post-merge which are currently provided without proof.

  if not (header.blockHash() == hash):
    err("Block header hash does not match")
  else:
    ok(header)

proc validateBlockBody*(
    body: PortalBlockBodyLegacy, header: BlockHeader
): Result[void, string] =
  ## Validate the block body against the txRoot and ommersHash from the header.
  let calculatedOmmersHash = keccakHash(body.uncles.asSeq())
  if calculatedOmmersHash != header.ommersHash:
    return err("Invalid ommers hash")

  let calculatedTxsRoot = calcTxsRoot(body.transactions)
  if calculatedTxsRoot != header.txRoot:
    return err(
      "Invalid transactions root: expected " & $header.txRoot & " - got " &
        $calculatedTxsRoot
    )

  ok()

proc validateBlockBody*(
    body: PortalBlockBodyShanghai, header: BlockHeader
): Result[void, string] =
  ## Validate the block body against the txRoot, ommersHash and withdrawalsRoot
  ## from the header.
  # Shortcut the ommersHash calculation as uncles must be an RLP encoded
  # empty list
  if body.uncles.asSeq() != @[byte 0xc0]:
    return err("Invalid ommers hash, uncles list is not empty")

  let calculatedTxsRoot = calcTxsRoot(body.transactions)
  if calculatedTxsRoot != header.txRoot:
    return err(
      "Invalid transactions root: expected " & $header.txRoot & " - got " &
        $calculatedTxsRoot
    )

  # TODO: This check is done higher up but perhaps this can become cleaner with
  # some refactor.
  doAssert(header.withdrawalsRoot.isSome())

  let
    calculatedWithdrawalsRoot = calcWithdrawalsRoot(body.withdrawals)
    headerWithdrawalsRoot = header.withdrawalsRoot.get()
  if calculatedWithdrawalsRoot != headerWithdrawalsRoot:
    return err(
      "Invalid withdrawals root: expected " & $headerWithdrawalsRoot & " - got " &
        $calculatedWithdrawalsRoot
    )

  ok()

proc decodeBlockBodyBytes*(bytes: openArray[byte]): Result[BlockBody, string] =
  if (let body = decodeSsz(bytes, PortalBlockBodyShanghai); body.isOk()):
    BlockBody.fromPortalBlockBody(body.get())
  elif (let body = decodeSsz(bytes, PortalBlockBodyLegacy); body.isOk()):
    BlockBody.fromPortalBlockBody(body.get())
  else:
    err("All Portal block body decodings failed")

proc validateBlockBodyBytes*(
    bytes: openArray[byte], header: BlockHeader
): Result[BlockBody, string] =
  ## Fully decode the SSZ encoded Portal Block Body and validate it against the
  ## header.
  ## TODO: improve this decoding in combination with the block body validation
  ## calls.
  let timestamp = Moment.init(header.timestamp.int64, Second)
  # TODO: The additional header checks are not needed as header is implicitly
  # verified by means of the accumulator? Except that we don't use this yet
  # post merge, so the checks are still useful, for now.
  if isShanghai(chainConfig, timestamp):
    if header.withdrawalsRoot.isNone():
      return err("Expected withdrawalsRoot for Shanghai block")
    elif header.ommersHash != EMPTY_UNCLE_HASH:
      return err("Expected empty uncles for a Shanghai block")
    else:
      let body = ?decodeSsz(bytes, PortalBlockBodyShanghai)
      ?validateBlockBody(body, header)
      BlockBody.fromPortalBlockBody(body)
  elif isPoSBlock(chainConfig, header.number):
    if header.withdrawalsRoot.isSome():
      return err("Expected no withdrawalsRoot for pre Shanghai block")
    elif header.ommersHash != EMPTY_UNCLE_HASH:
      return err("Expected empty uncles for a PoS block")
    else:
      let body = ?decodeSsz(bytes, PortalBlockBodyLegacy)
      ?validateBlockBody(body, header)
      BlockBody.fromPortalBlockBody(body)
  else:
    if header.withdrawalsRoot.isSome():
      return err("Expected no withdrawalsRoot for pre Shanghai block")
    else:
      let body = ?decodeSsz(bytes, PortalBlockBodyLegacy)
      ?validateBlockBody(body, header)
      BlockBody.fromPortalBlockBody(body)

proc validateReceipts*(
    receipts: PortalReceipts, receiptsRoot: KeccakHash
): Result[void, string] =
  let calculatedReceiptsRoot = calcReceiptsRoot(receipts)

  if calculatedReceiptsRoot != receiptsRoot:
    return err("Unexpected receipt root")
  else:
    return ok()

proc validateReceiptsBytes*(
    bytes: openArray[byte], receiptsRoot: KeccakHash
): Result[seq[Receipt], string] =
  ## Fully decode the SSZ encoded receipts and validate it against the header's
  ## receipts root.
  let receipts = ?decodeSsz(bytes, PortalReceipts)

  ?validateReceipts(receipts, receiptsRoot)

  seq[Receipt].fromPortalReceipts(receipts)

## ContentDB helper calls for specific history network types

proc get(db: ContentDB, T: type BlockHeader, contentId: ContentId): Opt[T] =
  let contentFromDB = db.get(contentId)
  if contentFromDB.isSome():
    let headerWithProof =
      try:
        SSZ.decode(contentFromDB.get(), BlockHeaderWithProof)
      except SerializationError as e:
        raiseAssert(e.msg)

    let res = decodeRlp(headerWithProof.header.asSeq(), T)
    if res.isErr():
      raiseAssert(res.error)
    else:
      Opt.some(res.get())
  else:
    Opt.none(T)

proc get(
    db: ContentDB, T: type BlockBody, contentId: ContentId, header: BlockHeader
): Opt[T] =
  let encoded = db.get(contentId).valueOr:
    return Opt.none(T)

  let
    timestamp = Moment.init(header.timestamp.int64, Second)
    body =
      if isShanghai(chainConfig, timestamp):
        BlockBody.fromPortalBlockBodyOrRaise(
          decodeSszOrRaise(encoded, PortalBlockBodyShanghai)
        )
      elif isPoSBlock(chainConfig, header.number):
        BlockBody.fromPortalBlockBodyOrRaise(
          decodeSszOrRaise(encoded, PortalBlockBodyLegacy)
        )
      else:
        BlockBody.fromPortalBlockBodyOrRaise(
          decodeSszOrRaise(encoded, PortalBlockBodyLegacy)
        )

  Opt.some(body)

proc get(db: ContentDB, T: type seq[Receipt], contentId: ContentId): Opt[T] =
  let contentFromDB = db.getSszDecoded(contentId, PortalReceipts)
  if contentFromDB.isSome():
    let res = T.fromPortalReceipts(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      Opt.some(res.get())
  else:
    Opt.none(T)

proc get(db: ContentDB, T: type EpochRecord, contentId: ContentId): Opt[T] =
  db.getSszDecoded(contentId, T)

proc getContentFromDb(n: HistoryNetwork, T: type, contentId: ContentId): Opt[T] =
  if n.portalProtocol.inRange(contentId):
    n.contentDB.get(T, contentId)
  else:
    Opt.none(T)

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
    n: HistoryNetwork, header: BlockHeader, proof: BlockHeaderProof
): Result[void, string] =
  verifyHeader(n.accumulator, header, proof)

proc getVerifiedBlockHeader*(
    n: HistoryNetwork, hash: BlockHash
): Future[Opt[BlockHeader]] {.async: (raises: [CancelledError]).} =
  let
    contentKey = ContentKey.init(blockHeader, hash).encode()
    contentId = contentKey.toContentId()

  logScope:
    hash
    contentKey

  # Note: This still requests a BlockHeaderWithProof from the database, as that
  # is what is stored. But the proof doesn't need to be verified as it gets
  # gets verified before storing.
  let headerFromDb = n.getContentFromDb(BlockHeader, contentId)
  if headerFromDb.isSome():
    info "Fetched block header from database"
    return headerFromDb

  for i in 0 ..< requestRetries:
    let
      headerContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        warn "Failed fetching block header with proof from the network"
        return Opt.none(BlockHeader)

      headerWithProof = decodeSsz(headerContent.content, BlockHeaderWithProof).valueOr:
        warn "Failed decoding header with proof", error
        continue

      header = validateBlockHeaderBytes(headerWithProof.header.asSeq(), hash).valueOr:
        warn "Validation of block header failed", error
        continue

    if (let r = n.verifyHeader(header, headerWithProof.proof); r.isErr):
      warn "Verification of block header failed", error = r.error
      continue

    info "Fetched valid block header from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(contentKey, contentId, headerContent.content)
    n.portalProtocol.triggerPoke(
      headerContent.nodesInterestedInContent, contentKey, headerContent.content
    )

    return Opt.some(header)

  # Headers were requested `requestRetries` times and all failed on validation
  return Opt.none(BlockHeader)

proc getBlockBody*(
    n: HistoryNetwork, hash: BlockHash, header: BlockHeader
): Future[Opt[BlockBody]] {.async: (raises: [CancelledError]).} =
  if header.txRoot == EMPTY_ROOT_HASH and header.ommersHash == EMPTY_UNCLE_HASH:
    # Short path for empty body indicated by txRoot and ommersHash
    return Opt.some(BlockBody(transactions: @[], uncles: @[]))

  let
    contentKey = ContentKey.init(blockBody, hash).encode()
    contentId = contentKey.toContentId()

  logScope:
    hash
    contentKey

  let bodyFromDb = n.contentDB.get(BlockBody, contentId, header)
  if bodyFromDb.isSome():
    info "Fetched block body from database"
    return bodyFromDb

  for i in 0 ..< requestRetries:
    let
      bodyContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        warn "Failed fetching block body from the network"
        return Opt.none(BlockBody)

      body = validateBlockBodyBytes(bodyContent.content, header).valueOr:
        warn "Validation of block body failed", error
        continue

    info "Fetched block body from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(contentKey, contentId, bodyContent.content)
    n.portalProtocol.triggerPoke(
      bodyContent.nodesInterestedInContent, contentKey, bodyContent.content
    )

    return Opt.some(body)

  # Bodies were requested `requestRetries` times and all failed on validation
  return Opt.none(BlockBody)

proc getBlock*(
    n: HistoryNetwork, hash: BlockHash
): Future[Opt[Block]] {.async: (raises: [CancelledError]).} =
  debug "Trying to retrieve block with hash", hash

  # Note: Using `getVerifiedBlockHeader` instead of getBlockHeader even though
  # proofs are not necessiarly needed, in order to avoid having to inject
  # also the original type into the network.
  let
    header = (await n.getVerifiedBlockHeader(hash)).valueOr:
      warn "Failed to get header when getting block", hash
      return Opt.none(Block)
    body = (await n.getBlockBody(hash, header)).valueOr:
      warn "Failed to get body when getting block", hash
      return Opt.none(Block)

  return Opt.some((header, body))

proc getReceipts*(
    n: HistoryNetwork, hash: BlockHash, header: BlockHeader
): Future[Opt[seq[Receipt]]] {.async: (raises: [CancelledError]).} =
  if header.receiptsRoot == EMPTY_ROOT_HASH:
    # Short path for empty receipts indicated by receipts root
    return Opt.some(newSeq[Receipt]())

  let
    contentKey = ContentKey.init(receipts, hash).encode()
    contentId = contentKey.toContentId()

  logScope:
    hash
    contentKey

  let receiptsFromDb = n.getContentFromDb(seq[Receipt], contentId)
  if receiptsFromDb.isSome():
    info "Fetched receipts from database"
    return receiptsFromDb

  for i in 0 ..< requestRetries:
    let
      receiptsContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        warn "Failed fetching receipts from the network"
        return Opt.none(seq[Receipt])
      receipts = validateReceiptsBytes(receiptsContent.content, header.receiptsRoot).valueOr:
        warn "Validation of receipts failed", error
        continue

    info "Fetched receipts from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(contentKey, contentId, receiptsContent.content)
    n.portalProtocol.triggerPoke(
      receiptsContent.nodesInterestedInContent, contentKey, receiptsContent.content
    )

    return Opt.some(receipts)

proc getEpochRecord(
    n: HistoryNetwork, epochHash: Digest
): Future[Opt[EpochRecord]] {.async: (raises: [CancelledError]).} =
  let
    contentKey = ContentKey.init(epochRecord, epochHash).encode()
    contentId = contentKey.toContentId()

  logScope:
    epochHash
    contentKey

  let accumulatorFromDb = n.getContentFromDb(EpochRecord, contentId)
  if accumulatorFromDb.isSome():
    info "Fetched epoch accumulator from database"
    return accumulatorFromDb

  for i in 0 ..< requestRetries:
    let
      accumulatorContent = (await n.portalProtocol.contentLookup(contentKey, contentId)).valueOr:
        warn "Failed fetching epoch accumulator from the network"
        return Opt.none(EpochRecord)

      epochRecord =
        try:
          SSZ.decode(accumulatorContent.content, EpochRecord)
        except SerializationError:
          continue

    let hash = hash_tree_root(epochRecord)
    if hash == epochHash:
      info "Fetched epoch accumulator from the network"
      n.portalProtocol.storeContent(contentKey, contentId, accumulatorContent.content)
      n.portalProtocol.triggerPoke(
        accumulatorContent.nodesInterestedInContent, contentKey,
        accumulatorContent.content,
      )

      return Opt.some(epochRecord)
    else:
      warn "Validation of epoch accumulator failed", resultedEpochHash = hash

  return Opt.none(EpochRecord)

proc getBlockHashByNumber*(
    n: HistoryNetwork, bn: UInt256
): Future[Result[BlockHash, string]] {.async: (raises: [CancelledError]).} =
  let
    epochData = n.accumulator.getBlockEpochDataForBlockNumber(bn).valueOr:
      return err(error)
    digest = Digest(data: epochData.epochHash)
    epoch = (await n.getEpochRecord(digest)).valueOr:
      return err("Cannot retrieve epoch accumulator for given block number")

  ok(epoch[epochData.blockRelativeIndex].blockHash)

proc getBlock*(
    n: HistoryNetwork, bn: UInt256
): Future[Result[Opt[Block], string]] {.async: (raises: [CancelledError]).} =
  let
    blockHash = ?(await n.getBlockHashByNumber(bn))
    maybeBlock = await n.getBlock(blockHash)

  return ok(maybeBlock)

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKey: ContentKeyByteList
): Future[bool] {.async: (raises: [CancelledError]).} =
  let key = contentKey.decode().valueOr:
    return false

  case key.contentType
  of blockHeader:
    let
      headerWithProof = decodeSsz(content, BlockHeaderWithProof).valueOr:
        warn "Failed decoding header with proof", error
        return false
      header = validateBlockHeaderBytes(
        headerWithProof.header.asSeq(), key.blockHeaderKey.blockHash
      ).valueOr:
        warn "Invalid block header offered", error
        return false

    let res = n.verifyHeader(header, headerWithProof.proof)
    if res.isErr():
      warn "Failed on check if header is part of canonical chain", error = res.error
      return false
    else:
      return true
  of blockBody:
    let header = (await n.getVerifiedBlockHeader(key.blockBodyKey.blockHash)).valueOr:
      warn "Failed getting canonical header for block"
      return false

    let res = validateBlockBodyBytes(content, header)
    if res.isErr():
      warn "Failed validating block body", error = res.error
      return false
    else:
      return true
  of receipts:
    let header = (await n.getVerifiedBlockHeader(key.receiptsKey.blockHash)).valueOr:
      warn "Failed getting canonical header for receipts"
      return false

    let res = validateReceiptsBytes(content, header.receiptsRoot)
    if res.isErr():
      warn "Failed validating receipts", error = res.error
      return false
    else:
      return true
  of epochRecord:
    # Check first if epochHash is part of master accumulator
    let epochHash = key.epochRecordKey.epochHash
    if not n.accumulator.historicalEpochs.contains(epochHash.data):
      warn "Offered epoch accumulator is not part of master accumulator", epochHash
      return false

    let epochRecord =
      try:
        SSZ.decode(content, EpochRecord)
      except SerializationError:
        warn "Failed decoding epoch accumulator"
        return false

    # Next check the hash tree root, as this is probably more expensive
    let hash = hash_tree_root(epochRecord)
    if hash != epochHash:
      warn "Epoch accumulator has invalid root hash"
      return false
    else:
      return true

proc new*(
    T: type HistoryNetwork,
    portalNetwork: PortalNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    accumulator: FinishedAccumulator,
    historicalRoots: HistoricalRoots = loadHistoricalRoots(),
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig,
): T =
  let
    contentQueue = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)

    stream = streamManager.registerNewStream(contentQueue)

    portalProtocol = PortalProtocol.new(
      baseProtocol,
      getProtocolId(portalNetwork, PortalSubnetwork.history),
      toContentIdHandler,
      createGetHandler(contentDB),
      stream,
      bootstrapRecords,
      config = portalConfig,
    )

  portalProtocol.dbPut =
    createStoreHandler(contentDB, portalConfig.radiusConfig, portalProtocol)

  HistoryNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: contentQueue,
    accumulator: accumulator,
    historicalRoots: historicalRoots,
  )

proc validateContent(
    n: HistoryNetwork, contentKeys: ContentKeysList, contentItems: seq[seq[byte]]
): Future[bool] {.async: (raises: [CancelledError]).} =
  # content passed here can have less items then contentKeys, but not more.
  for i, contentItem in contentItems:
    let contentKey = contentKeys[i]
    if await n.validateContent(contentItem, contentKey):
      let contentId = n.portalProtocol.toContentId(contentKey).valueOr:
        error "Received offered content with invalid content key", contentKey
        return false

      n.portalProtocol.storeContent(contentKey, contentId, contentItem)

      info "Received offered content validated successfully", contentKey
    else:
      error "Received offered content failed validation", contentKey
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
      if await n.validateContent(contentKeys, contentItems):
        asyncSpawn n.portalProtocol.neighborhoodGossipDiscardPeers(
          srcNodeId, contentKeys, contentItems
        )
  except CancelledError:
    trace "processContentLoop canceled"

proc statusLogLoop(n: HistoryNetwork) {.async: (raises: []).} =
  try:
    while true:
      # This is the data radius percentage compared to full storage. This will
      # drop a lot when using the logbase2 scale, namely `/ 2` per 1 logaritmic
      # radius drop.
      # TODO: Get some float precision calculus?
      let radiusPercentage =
        n.portalProtocol.dataRadius div (UInt256.high() div u256(100))

      info "History network status",
        radius = radiusPercentage.toString(10) & "%",
        dbSize = $(n.contentDB.size() div 1000) & "kb",
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

proc stop*(n: HistoryNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancelSoon()

  if not n.processContentLoop.isNil:
    n.statusLogLoop.cancelSoon()
