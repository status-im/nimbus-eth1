# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[options, tables],
  stew/results, chronos, chronicles, nimcrypto/[keccak, hash],
  eth/[common/eth_types, rlp, trie, trie/db],
  eth/p2p/discoveryv5/[protocol, enr],
  ../../content_db,
  ../../../nimbus/constants,
  ../wire/[portal_protocol, portal_stream, portal_protocol_config],
  "."/[history_content, accumulator],
  ../../populate_db

logScope:
  topics = "portal_hist"

export accumulator

# TODO: To currently verify if content is from the canonical chain it is
# required to download the right epoch accunulator, which is ~0.5 MB. This is
# too much, at least for the local testnet tests. This needs to be improved
# by adding the proofs to the block header content. Another independent
# improvement would be to have a content cache (LRU or so). The latter would
# probably help mostly for the local testnet tests.
# For now, we disable this verification default until further improvements are
# made.
const canonicalVerify* {.booldefine.} = false

const
  historyProtocolId* = [byte 0x50, 0x0B]

type
  HistoryNetwork* = ref object
    portalProtocol*: PortalProtocol
    contentDB*: ContentDB
    contentQueue*: AsyncQueue[(ContentKeysList, seq[seq[byte]])]
    processContentLoop: Future[void]

  Block* = (BlockHeader, BlockBody)

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

## ContentDB helper calls for specific history network types

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

proc get(
    db: ContentDB, T: type EpochAccumulator, contentId: ContentID): Option[T] =
  db.getSszDecoded(contentId, T)

proc getAccumulator(db: ContentDB): Option[Accumulator] =
  db.getPermanentSszDecoded(subkey(kLatestAccumulator), Accumulator)

proc putAccumulator*(db: ContentDB, value: openArray[byte]) =
  db.putPermanent(subkey(kLatestAccumulator), value)

proc getContentFromDb(
    n: HistoryNetwork, T: type, contentId: ContentId): Option[T] =
  if n.portalProtocol.inRange(contentId):
    n.contentDB.get(T, contentId)
  else:
    none(T)

proc dbGetHandler(db: ContentDB, contentKey: ByteList):
    (Option[ContentId], Option[seq[byte]]) {.raises: [Defect], gcsafe.} =
  let keyOpt = decode(contentKey)
  if keyOpt.isNone():
    return (none(ContentId), none(seq[byte]))

  let key = keyOpt.get()

  case key.contentType:
  of masterAccumulator:
    (none(ContentId), db.getPermanent(subkey(kLatestAccumulator)))
  else:
    let contentId = key.toContentId()
    (some(contentId), db.get(contentId))

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

      n.portalProtocol.storeContent(contentId, headerContent.content)

      return some(res.get())
    else:
      warn "Validation of block header failed", err = res.error, hash, contentKey = keyEncoded

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

      n.portalProtocol.storeContent(contentId, bodyContent.content)

      return some(res.get())
    else:
      warn "Validation of block body failed", err = res.error, hash, contentKey = keyEncoded

  return none(BlockBody)

proc getBlock*(
    n: HistoryNetwork, chainId: uint16, hash: BlockHash):
    Future[Option[Block]] {.async.} =
  debug "Trying to retrieve block with hash", hash

  let headerOpt = await n.getBlockHeader(chainId, hash)
  if headerOpt.isNone():
    warn "Failed to get header when getting block with hash", hash
    # Cannot validate block without header.
    return none(Block)

  let header = headerOpt.unsafeGet()

  let bodyOpt = await n.getBlockBody(chainId, hash, header)

  if bodyOpt.isNone():
    warn "Failed to get body when gettin block with hash", hash
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

      n.portalProtocol.storeContent(contentId, receiptsContent.content)

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

      n.portalProtocol.storeContent(contentId, accumulatorContent.content)

      return some(epochAccumulator)
    else:
      warn "Validation of epoch accumulator failed",
        hash, expectedHash = epochHash

  return none(EpochAccumulator)

proc getBlock*(
    n: HistoryNetwork, chainId: uint16, bn: Uint256):
    Future[Result[Option[Block], string]] {.async.} =

  # TODO for now checking accumulator only in db, we could also ask our
  # peers for it.
  let accumulatorOpt = n.contentDB.getAccumulator()

  if accumulatorOpt.isNone():
    return err("Master accumulator not found in database")

  let accumulator = accumulatorOpt.unsafeGet()

  let hashResponse = accumulator.getHeaderHashForBlockNumber(bn)

  case hashResponse.kind
  of BHash:
    # we got header hash in current epoch accumulator, try to retrieve it from network
    let blockResponse = await n.getBlock(chainId, hashResponse.blockHash)
    return ok(blockResponse)
  of HEpoch:
    let digest = Digest(data: hashResponse.epochHash)

    let epochOpt = await n.getEpochAccumulator(digest)

    if epochOpt.isNone():
      return err("Cannot retrieve epoch accumulator for given block number")

    let
      epoch = epochOpt.unsafeGet()
      blockHash = epoch[hashResponse.blockRelativeIndex].blockHash

    let maybeBlock = await n.getBlock(chainId, blockHash)

    return ok(maybeBlock)
  of UnknownBlockNumber:
    return err("Block number not included in master accumulator")

proc getInitialMasterAccumulator*(
    n: HistoryNetwork):
    Future[bool] {.async.} =
  let
    contentKey = ContentKey(
      contentType: masterAccumulator,
      masterAccumulatorKey: MasterAccumulatorKey(accumulaterKeyType: latest))
    keyEncoded = encode(contentKey)

  let nodes = await n.portalProtocol.queryRandom()

  var hashes: CountTable[Accumulator]

  for node in nodes:
    # TODO: Could make concurrent
    let foundContentRes = await n.portalProtocol.findContent(node, keyEncoded)
    if foundContentRes.isOk():
      let foundContent = foundContentRes.get()
      if foundContent.kind == Content:
        let masterAccumulator =
          try:
            SSZ.decode(foundContent.content, Accumulator)
          except SszError:
            continue
        hashes.inc(masterAccumulator)
        let (accumulator, count) = hashes.largest()

        if count > 1: # Should be increased eventually
          n.contentDB.putAccumulator(foundContent.content)
          return true

  # Could not find a common accumulator from all the queried nodes
  return false

proc buildProof*(n: HistoryNetwork, header: BlockHeader):
    Future[Result[seq[Digest], string]] {.async.} =
  # Note: Temporarily needed proc until proofs are send over with headers.
  let accumulatorOpt = n.contentDB.getAccumulator()
  if accumulatorOpt.isNone():
    return err("Master accumulator not found in database")

  let
    accumulator = accumulatorOpt.get()
    epochIndex = getEpochIndex(header)
    epochHash = Digest(data: accumulator.historicalEpochs[epochIndex])

    epochAccumulatorOpt = await n.getEpochAccumulator(epochHash)

  if epochAccumulatorOpt.isNone():
    return err("Epoch accumulator not found")

  let
    epochAccumulator = epochAccumulatorOpt.get()
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)
    # TODO: Implement more generalized `get_generalized_index`
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  return epochAccumulator.build_proof(gIndex)

proc verifyCanonicalChain(
    n: HistoryNetwork, header: BlockHeader):
    Future[Result[void, string]] {.async.} =
  when not canonicalVerify:
    return ok()

  let accumulatorOpt = n.contentDB.getAccumulator()
  if accumulatorOpt.isNone():
    # Should acquire a master accumulator first
    return err("Cannot accept any data without a master accumulator")

  let accumulator = accumulatorOpt.get()

  # Note: It is a bit silly to build a proof, as we still need to request the
  # epoch accumulators for it, and could just verify it with those. But the
  # idea here is that eventually this gets changed so that the proof is send
  # together with the header.
  let proofOpt =
    if header.inCurrentEpoch(accumulator):
      none(seq[Digest])
    else:
      let proof = await n.buildProof(header)
      if proof.isErr():
        # Can't verify without master and epoch accumulators
        return err("Cannot build proof: " & proof.error)
      else:
        some(proof.get())

  return verifyHeader(accumulator, header, proofOpt)

proc validateContent(
    n: HistoryNetwork, content: seq[byte], contentKey: ByteList):
    Future[bool] {.async.} =
  let keyOpt = contentKey.decode()

  if keyOpt.isNone():
    return false

  let key = keyOpt.get()

  case key.contentType:
  of blockHeader:
    let validateResult =
      validateBlockHeaderBytes(content, key.blockHeaderKey.blockHash)
    if validateResult.isErr():
      warn "Invalid block header offered", error = validateResult.error
      return false

    let header = validateResult.get()

    let verifyResult = await n.verifyCanonicalChain(header)
    if verifyResult.isErr():
      warn "Failed on check if header is part of canonical chain",
        error = verifyResult.error
      return false
    else:
      return true
  of blockBody:
    let headerOpt = await n.getBlockHeader(
      key.blockBodyKey.chainId, key.blockBodyKey.blockHash)

    if headerOpt.isNone():
      warn "Cannot find the header, no way to validate the block body"
      return false

    let header = headerOpt.get()
    let validationResult =
      validateBlockBodyBytes(content, header.txRoot, header.ommersHash)

    if validationResult.isErr():
      warn "Failed validating block body", error = validationResult.error
      return false

    let verifyResult = await n.verifyCanonicalChain(header)
    if verifyResult.isErr():
      warn "Failed on check if header is part of canonical chain",
        error = verifyResult.error
      return false
    else:
      return true
  of receipts:
    let headerOpt = await n.getBlockHeader(
      key.receiptsKey.chainId, key.receiptsKey.blockHash)

    if headerOpt.isNone():
      warn "Cannot find the header, no way to validate the receipts"
      return false

    let header = headerOpt.get()
    let validationResult =
      validateReceiptsBytes(content, header.receiptRoot)

    if validationResult.isErr():
      warn "Failed validating receipts", error = validationResult.error
      return false

    let verifyResult = await n.verifyCanonicalChain(header)
    if verifyResult.isErr():
      warn "Failed on check if header is part of canonical chain",
        error = verifyResult.error
      return false
    else:
      return true
  of epochAccumulator:
    # Check first if epochHash is part of master accumulator
    let masterAccumulator = n.contentDB.getAccumulator()
    if masterAccumulator.isNone():
      error "Cannot accept any data without a master accumulator"
      return false

    let epochHash = key.epochAccumulatorKey.epochHash

    if not masterAccumulator.get().historicalEpochs.contains(epochHash.data):
      warn "Offered epoch accumulator is not part of master accumulator"
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
  of masterAccumulator:
    # Don't allow a master accumulator to be offered, we only request it.
    warn "Node does not accept master accumulators through offer/accept"
    return false

proc new*(
    T: type HistoryNetwork,
    baseProtocol: protocol.Protocol,
    contentDB: ContentDB,
    streamManager: StreamManager,
    bootstrapRecords: openArray[Record] = [],
    portalConfig: PortalProtocolConfig = defaultPortalProtocolConfig): T =

  let cq = newAsyncQueue[(ContentKeysList, seq[seq[byte]])](50)

  let s = streamManager.registerNewStream(cq)

  let portalProtocol = PortalProtocol.new(
    baseProtocol, historyProtocolId, contentDB,
    toContentIdHandler, dbGetHandler, s, bootstrapRecords,
    config = portalConfig)

  return HistoryNetwork(
    portalProtocol: portalProtocol,
    contentDB: contentDB,
    contentQueue: cq
  )

proc processContentLoop(n: HistoryNetwork) {.async.} =
  try:
    while true:
      let (contentKeys, contentItems) =
        await n.contentQueue.popFirst()

      # content passed here can have less items then contentKeys, but not more.
      for i, contentItem in contentItems:
        let contentKey = contentKeys[i]
        if await n.validateContent(contentItem, contentKey):
          let contentIdOpt = n.portalProtocol.toContentId(contentKey)
          if contentIdOpt.isNone():
            continue

          let contentId = contentIdOpt.get()

          n.portalProtocol.storeContent(contentId, contentItem)

          info "Received offered content validated successfully", contentKey
        else:
          error "Received offered content failed validation", contentKey
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

proc initMasterAccumulator*(
    n: HistoryNetwork,
    accumulator: Option[Accumulator]) {.async.} =
  if accumulator.isSome():
    n.contentDB.putAccumulator(SSZ.encode(accumulator.get()))
    info "Successfully retrieved master accumulator from local data"
  else:
    while true:
      if await n.getInitialMasterAccumulator():
        info "Successfully retrieved master accumulator from the network"
        return
      else:
        warn "Could not retrieve initial master accumulator from the network"
        when not canonicalVerify:
          return
        else:
          await sleepAsync(2.seconds)

proc stop*(n: HistoryNetwork) =
  n.portalProtocol.stop()

  if not n.processContentLoop.isNil:
    n.processContentLoop.cancel()
