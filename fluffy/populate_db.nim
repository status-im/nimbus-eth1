# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_serialization, json_serialization/std/tables,
  stew/[byteutils, io2, results], nimcrypto/keccak, chronos, chronicles,
  eth/[rlp, common/eth_types],
  # TODO: `NetworkId` should not be in these private types
  eth/p2p/private/p2p_types,
  ../nimbus/[chain_config, genesis],
  "."/[content_db, seed_db],
  ./network/wire/portal_protocol,
  ./network/history/history_content

export results, tables

# Helper calls to, offline, populate the database with the current existing json
# files with block data. Might move to some other storage format later on.
# Perhaps https://github.com/status-im/nimbus-eth2/blob/stable/docs/e2store.md
# can be interesting here too.

type
  BlockData* = object
    header*: string
    body*: string
    receipts*: string
    # TODO:
    # uint64, but then it expects a string for some reason.
    # Fix in nim-json-serialization or should I overload something here?
    number*: int

  BlockDataTable* = Table[string, BlockData]

proc readBlockDataTable*(dataFile: string): Result[BlockDataTable, string] =
  let blockData = readAllFile(dataFile)
  if blockData.isErr(): # TODO: map errors
    return err("Failed reading data-file")

  let decoded =
    try:
      Json.decode(blockData.get(), BlockDataTable)
    except CatchableError as e:
      return err("Failed decoding json data-file: " & e.msg)

  ok(decoded)

iterator blockHashes*(blockData: BlockDataTable): BlockHash =
  for k,v in blockData:
    var blockHash: BlockHash
    try:
      blockHash.data = hexToByteArray[sizeof(BlockHash)](k)
    except ValueError as e:
      error "Invalid hex for block hash", error = e.msg, number = v.number
      continue

    yield blockHash

func readBlockData(
    hash: string, blockData: BlockData, verify = false):
    Result[seq[(ContentKey, seq[byte])], string] =
  var res: seq[(ContentKey, seq[byte])]

  var blockHash: BlockHash
  try:
    blockHash.data = hexToByteArray[sizeof(BlockHash)](hash)
  except ValueError as e:
    return err("Invalid hex for blockhash, number " &
      $blockData.number & ": " & e.msg)

  let contentKeyType =
    BlockKey(chainId: 1'u16, blockHash: blockHash)

  try:
    # If wanted the hash for the corresponding header can be verified
    if verify:
      if keccak256.digest(blockData.header.hexToSeqByte()) != blockHash:
        return err("Data is not matching hash, number " & $blockData.number)

    block:
      let contentKey = ContentKey(
        contentType: blockHeader,
        blockHeaderKey: contentKeyType)

      res.add((contentKey, blockData.header.hexToSeqByte()))

    block:
      let contentKey = ContentKey(
        contentType: blockBody,
        blockBodyKey: contentKeyType)

      res.add((contentKey, blockData.body.hexToSeqByte()))

    block:
      let contentKey = ContentKey(
        contentType: receipts,
        receiptsKey: contentKeyType)

      res.add((contentKey, blockData.receipts.hexToSeqByte()))

  except ValueError as e:
    return err("Invalid hex data, number " & $blockData.number & ": " & e.msg)

  ok(res)

iterator blocks*(
    blockData: BlockDataTable, verify = false): seq[(ContentKey, seq[byte])] =
  for k,v in blockData:
    let res = readBlockData(k, v, verify)

    if res.isOk():
      yield res.get()
    else:
      error "Failed reading block from block data", error = res.error

func readBlockHeader*(blockData: BlockData): Result[BlockHeader, string] =
  var rlp =
    try:
      rlpFromHex(blockData.header)
    except ValueError as e:
      return err("Invalid hex for rlp block data, number " &
        $blockData.number & ": " & e.msg)

  try:
    return ok(rlp.read(BlockHeader))
  except RlpError as e:
    return err("Invalid header, number " & $blockData.number & ": " & e.msg)

proc getGenesisHeader*(id: NetworkId = MainNet): BlockHeader =
  let params =
    try:
      networkParams(id)
    except ValueError, RlpError:
      raise (ref Defect)(msg: "Network parameters should be valid")

  try:
    toGenesisHeader(params)
  except RlpError:
    raise (ref Defect)(msg: "Genesis should be valid")

proc historyStore*(
    p: PortalProtocol, dataFile: string, verify = false):
    Result[void, string] =
  let blockData = ? readBlockDataTable(dataFile)

  for b in blocks(blockData, verify):
    for value in b:
      # Note: This is the slowest part due to the hashing that takes place.
      p.storeContent(history_content.toContentId(value[0]), value[1])

  ok()

proc historyPropagate*(
    p: PortalProtocol, dataFile: string, verify = false):
    Future[Result[void, string]] {.async.} =
  const concurrentGossips = 20

  var gossipQueue =
    newAsyncQueue[(ContentKeysList, seq[byte])](concurrentGossips)
  var gossipWorkers: seq[Future[void]]

  proc gossipWorker(p: PortalProtocol) {.async.} =
    while true:
      let (keys, content) = await gossipQueue.popFirst()

      await p.neighborhoodGossip(keys, @[content])

  for i in 0 ..< concurrentGossips:
    gossipWorkers.add(gossipWorker(p))

  let blockData = readBlockDataTable(dataFile)
  if blockData.isOk():
    for b in blocks(blockData.get(), verify):
      for value in b:
        # Only sending non empty data, e.g. empty receipts are not send
        # TODO: Could do a similar thing for a combination of empty
        # txs and empty uncles, as then the serialization is always the same.
        if value[1].len() > 0:
          info "Seeding block content into the network", contentKey = value[0]
          # Note: This is the slowest part due to the hashing that takes place.
          let contentId = history_content.toContentId(value[0])
          p.storeContent(contentId, value[1])

          await gossipQueue.addLast(
            (ContentKeysList(@[encode(value[0])]), value[1]))

    return ok()
  else:
    return err(blockData.error)

proc historyPropagateBlock*(
    p: PortalProtocol, dataFile: string, blockHash: string, verify = false):
    Future[Result[void, string]] {.async.} =
  let blockDataTable = readBlockDataTable(dataFile)

  if blockDataTable.isOk():
    let b =
      try:
        blockDataTable.get()[blockHash]
      except KeyError:
        return err("Block hash not found in block data file")

    let blockDataRes = readBlockData(blockHash, b)
    if blockDataRes.isErr:
      return err(blockDataRes.error)

    let blockData = blockDataRes.get()

    for value in blockData:
      info "Seeding block content into the network", contentKey = value[0]
      let contentId = history_content.toContentId(value[0])
      p.storeContent(contentId, value[1])

      await p.neighborhoodGossip(ContentKeysList(@[encode(value[0])]), @[value[1]])

    return ok()
  else:
    return err(blockDataTable.error)

proc historyGetHashesInRange*(
  db: SeedDb,
  nodeId: UInt256,
  radius: UInt256,
  max: int64): seq[BlockHash] =
  var hashes: seq[BlockHash]

  let contentsInRange = db.getContentInRange(nodeId, radius, max)

  for c in contentsInRange:
    let keyBytes = ByteList.init(c.contentKey)
    # if this fails, it means it is not valid seed_db for history content, it good
    # fails fast as either it is db with different content type or for some reason
    # history seed db has bad keys in it.
    let keyDecoded = decode(keyBytes).unsafeGet()

    # this silently assumes that we have full headers, bodies, receipts, for given
    # hashes in SeedDb
    if keyDecoded.contentType == blockheader:
      hashes.add(keyDecoded.blockHeaderKey.blockHash)

  return hashes
