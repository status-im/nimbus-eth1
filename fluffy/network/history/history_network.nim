# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
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

# This looks like it makes no sense, because it makes no sense. It's a
# workaround for what seems to be a compiler bug; see here:
#
# https://github.com/status-im/nimbus-eth1/pull/1465
#
# Without this, the call `error` on a `Result` might give a compiler error for
# the `Result[BlockHeader, string]` or `Result[seq[BlockHeader], string]` types.
# The error is due to the `$` for `BlockHeader causing side effects, which
# appears to be due to the timestamp field, which is of `times.Time` type. Its
# `$` from the times module has side effects (Yes, silly times). In (my) theory
# this `$` should not leak here, but it seems to do. To workaround this we
# introduce this additional `$` call, which appears to work.
#
# Note that this also fixes the same error in another module, even when not
# specifically exporting (no asterisk) the call.
#
# If you think this is unnecessary, feel free to try deleting it; if all the
# tests still pass after deleting it, feel free to leave it out. In the
# meantime, please just ignore it and go on with your life.
#
proc `$`(x: BlockHeader): string =
  $x

const
  historyProtocolId* = [byte 0x50, 0x0B]

type
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(ContentKeysList, seq[seq[byte]])]
    accumulator*: FinishedAccumulator
    processContentLoop: Future[void]
    statusLogLoop: Future[void]

  Block* = (BlockHeader, BlockBody)

func toContentIdHandler(contentKey: ByteList): results.Opt[ContentId] =
  ok(toContentId(contentKey))

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

func fromPortalBlockBody*(
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

func fromReceipts*(
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

func fromReceipts*(T: type ReceiptsSSZ, receipts: seq[Receipt]): T =
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
  for i, item in items:
    try:
      tr.put(rlp.encode(i), item.asSeq())
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

  if header.excessDataGas.isSome:
    return err("EIP-4844 not yet implemented")

  # TODO: Verify timestamp with Shanghai timestamp to if isSome()
  # TODO 2: Verify block number with merge block to check ommerhash

  if not (header.blockHash() == hash):
    err("Block header hash does not match")
  else:
    ok(header)

proc validateBlockBody(
    body: BlockBodySSZ, txsRoot, ommersHash: KeccakHash):
    Result[void, string] =
  ## Validate the block body against the txRoot amd ommersHash from the header.
  # TODO: should be checked for hash for empty uncles after merge block
  let calculatedOmmersHash = keccakHash(body.uncles.asSeq())
  if calculatedOmmersHash != ommersHash:
    return err("Invalid ommers hash")

  let calculatedTxsRoot = calcTxsRoot(body.transactions)
  if calculatedTxsRoot != txsRoot:
    return err("Invalid transactions root")

  # TODO: Add root check for withdrawals after Shanghai

  ok()

proc validateBlockBodyBytes*(
    bytes: openArray[byte], txRoot, ommersHash: KeccakHash):
    Result[BlockBody, string] =
  ## Fully decode the SSZ Block Body and validate it against the header.
  let body = ? decodeSsz(bytes, BlockBodySSZ)

  ? validateBlockBody(body, txRoot, ommersHash)

  BlockBody.fromPortalBlockBody(body)

proc validateReceipts*(
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

proc get(db: ContentDB, T: type BlockHeader, contentId: ContentId): Opt[T] =
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
      Opt.some(res.get())
  else:
    Opt.none(T)

proc get(db: ContentDB, T: type BlockBody, contentId: ContentId): Opt[T] =
  let contentFromDB = db.getSszDecoded(contentId, BlockBodySSZ)
  if contentFromDB.isSome():
    let res = T.fromPortalBlockBody(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      Opt.some(res.get())
  else:
    Opt.none(T)

proc get(db: ContentDB, T: type seq[Receipt], contentId: ContentId): Opt[T] =
  let contentFromDB = db.getSszDecoded(contentId, ReceiptsSSZ)
  if contentFromDB.isSome():
    let res = T.fromReceipts(contentFromDB.get())
    if res.isErr():
      raiseAssert(res.error)
    else:
      Opt.some(res.get())
  else:
    Opt.none(T)

proc get(
    db: ContentDB, T: type EpochAccumulator, contentId: ContentId): Opt[T] =
  db.getSszDecoded(contentId, T)

proc getContentFromDb(
    n: HistoryNetwork, T: type, contentId: ContentId): Opt[T] =
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
    n: HistoryNetwork, header: BlockHeader, proof: BlockHeaderProof):
    Result[void, string] =
  verifyHeader(n.accumulator, header, proof)

proc getVerifiedBlockHeader*(
    n: HistoryNetwork, hash: BlockHash):
    Future[Opt[BlockHeader]] {.async.} =
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

  for i in 0..<requestRetries:
    let
      headerContent = (await n.portalProtocol.contentLookup(
          contentKey, contentId)).valueOr:
        warn "Failed fetching block header with proof from the network"
        return Opt.none(BlockHeader)

      headerWithProof = decodeSsz(
          headerContent.content, BlockHeaderWithProof).valueOr:
        warn "Failed decoding header with proof", error
        continue

      header = validateBlockHeaderBytes(
          headerWithProof.header.asSeq(), hash).valueOr:
        warn "Validation of block header failed", error
        continue

    if (let r = n.verifyHeader(header, headerWithProof.proof); r.isErr):
      warn "Verification of block header failed", error = r.error
      continue

    info "Fetched valid block header from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(contentKey, contentId, headerContent.content)
    n.portalProtocol.triggerPoke(
      headerContent.nodesInterestedInContent,
      contentKey,
      headerContent.content
    )

    return Opt.some(header)

  # Headers were requested `requestRetries` times and all failed on validation
  return Opt.none(BlockHeader)

proc getBlockBody*(
    n: HistoryNetwork, hash: BlockHash, header: BlockHeader):
    Future[Opt[BlockBody]] {.async.} =
  if header.txRoot == EMPTY_ROOT_HASH and header.ommersHash == EMPTY_UNCLE_HASH:
    # Short path for empty body indicated by txRoot and ommersHash
    return Opt.some(BlockBody(transactions: @[], uncles: @[]))

  let
    contentKey = ContentKey.init(blockBody, hash).encode()
    contentId = contentKey.toContentId()

  logScope:
    hash
    contentKey

  let bodyFromDb = n.getContentFromDb(BlockBody, contentId)
  if bodyFromDb.isSome():
    info "Fetched block body from database"
    return bodyFromDb

  for i in 0..<requestRetries:
    let
      bodyContent = (await n.portalProtocol.contentLookup(
          contentKey, contentId)).valueOr:
        warn "Failed fetching block body from the network"
        return Opt.none(BlockBody)

      body = validateBlockBodyBytes(
          bodyContent.content, header.txRoot, header.ommersHash).valueOr:
        warn "Validation of block body failed", error
        continue

    info "Fetched block body from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(contentKey, contentId, bodyContent.content)
    n.portalProtocol.triggerPoke(
      bodyContent.nodesInterestedInContent,
      contentKey,
      bodyContent.content
    )

    return Opt.some(body)

  # Bodies were requested `requestRetries` times and all failed on validation
  return Opt.none(BlockBody)

proc getBlock*(
    n: HistoryNetwork, hash: BlockHash):
    Future[Opt[Block]] {.async.} =
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
    n: HistoryNetwork,
    hash: BlockHash,
    header: BlockHeader): Future[Opt[seq[Receipt]]] {.async.} =
  if header.receiptRoot == EMPTY_ROOT_HASH:
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

  for i in 0..<requestRetries:
    let
      receiptsContent = (await n.portalProtocol.contentLookup(
          contentKey, contentId)).valueOr:
        warn "Failed fetching receipts from the network"
        return Opt.none(seq[Receipt])
      receipts = validateReceiptsBytes(
          receiptsContent.content, header.receiptRoot).valueOr:
        warn "Validation of receipts failed", error
        continue

    info "Fetched receipts from the network"
    # Content is valid, it can be stored and propagated to interested peers
    n.portalProtocol.storeContent(contentKey, contentId, receiptsContent.content)
    n.portalProtocol.triggerPoke(
      receiptsContent.nodesInterestedInContent,
      contentKey,
      receiptsContent.content
    )

    return Opt.some(receipts)

proc getEpochAccumulator(
    n: HistoryNetwork, epochHash: Digest):
    Future[Opt[EpochAccumulator]] {.async.} =
  let
    contentKey = ContentKey.init(epochAccumulator, epochHash).encode()
    contentId = contentKey.toContentId()

  logScope:
    epochHash
    contentKey

  let accumulatorFromDb = n.getContentFromDb(EpochAccumulator, contentId)
  if accumulatorFromDb.isSome():
    info "Fetched epoch accumulator from database"
    return accumulatorFromDb

  for i in 0..<requestRetries:
    let
      accumulatorContent = (await n.portalProtocol.contentLookup(
          contentKey, contentId)).valueOr:
        warn "Failed fetching epoch accumulator from the network"
        return Opt.none(EpochAccumulator)

      epochAccumulator =
        try:
          SSZ.decode(accumulatorContent.content, EpochAccumulator)
        except SszError:
          continue

    let hash = hash_tree_root(epochAccumulator)
    if hash == epochHash:
      info "Fetched epoch accumulator from the network"
      n.portalProtocol.storeContent(contentKey, contentId, accumulatorContent.content)
      n.portalProtocol.triggerPoke(
        accumulatorContent.nodesInterestedInContent,
        contentKey,
        accumulatorContent.content
      )

      return Opt.some(epochAccumulator)
    else:
      warn "Validation of epoch accumulator failed", resultedEpochHash = hash

  return Opt.none(EpochAccumulator)

proc getBlock*(
    n: HistoryNetwork, bn: UInt256):
    Future[Result[Opt[Block], string]] {.async.} =
  let
    epochData = n.accumulator.getBlockEpochDataForBlockNumber(bn).valueOr:
      return err(error)
    digest = Digest(data: epochData.epochHash)
    epoch = (await n.getEpochAccumulator(digest)).valueOr:
      return err("Cannot retrieve epoch accumulator for given block number")
    blockHash = epoch[epochData.blockRelativeIndex].blockHash

    maybeBlock = await n.getBlock(blockHash)

  return ok(maybeBlock)

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKey: ByteList):
    Future[bool] {.async.} =
  let key = contentKey.decode().valueOr:
    return false

  case key.contentType:
  of blockHeader:
    let
      headerWithProof = decodeSsz(content, BlockHeaderWithProof).valueOr:
        warn "Failed decoding header with proof", error
        return false
      header = validateBlockHeaderBytes(
          headerWithProof.header.asSeq(),
          key.blockHeaderKey.blockHash).valueOr:
        warn "Invalid block header offered", error
        return false

    let res = n.verifyHeader(header, headerWithProof.proof)
    if res.isErr():
      warn "Failed on check if header is part of canonical chain",
        error = res.error
      return false
    else:
      return true

  of blockBody:
    let header = (await n.getVerifiedBlockHeader(
        key.blockBodyKey.blockHash)).valueOr:
      warn "Failed getting canonical header for block"
      return false

    let res = validateBlockBodyBytes(content, header.txRoot, header.ommersHash)
    if res.isErr():
      warn "Failed validating block body", error = res.error
      return false
    else:
      return true

  of receipts:
    let header = (await n.getVerifiedBlockHeader(
        key.receiptsKey.blockHash)).valueOr:
      warn "Failed getting canonical header for receipts"
      return false

    let res = validateReceiptsBytes(content, header.receiptRoot)
    if res.isErr():
      warn "Failed validating receipts", error = res.error
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

proc statusLogLoop(n: HistoryNetwork) {.async.} =
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
        contentSize = $(n.contentDB.contentSize() div 1000) & "kb",
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
    n.processContentLoop.cancel()
