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
  ./content_db,
  ./network/wire/portal_protocol,
  ./network/history/history_content

export results

# Helper calls to, offline, populate the database with the current existing json
# files with block data. Might move to some other storage format later on.
# Perhaps https://github.com/status-im/nimbus-eth2/blob/stable/docs/e2store.md
# can be interesting here too.

type
  BlockData* = object
    rlp: string
    # TODO:
    # uint64, but then it expects a string for some reason.
    # Fix in nim-json-serialization or should I overload something here?
    number: int

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

  var rlp =
    try:
      rlpFromHex(blockData.rlp)
    except ValueError as e:
      return err("Invalid hex for rlp block data, number " &
        $blockData.number & ": " & e.msg)

  # The data is currently formatted as an rlp encoded `EthBlock`, thus
  # containing header, txs and uncles: [header, txs, uncles]. No receipts are
  # available.
  # TODO: Change to format to rlp data as it gets stored and send over the
  # network over the network. I.e. [header, [txs, uncles], receipts]
  if rlp.enterList():
    var blockHash: BlockHash
    try:
      blockHash.data = hexToByteArray[sizeof(BlockHash)](hash)
    except ValueError as e:
      return err("Invalid hex for blockhash, number " &
        $blockData.number & ": " & e.msg)

    let contentKeyType =
      ContentKeyType(chainId: 1'u16, blockHash: blockHash)

    try:
      # If wanted the hash for the corresponding header can be verified
      if verify:
        if keccak256.digest(rlp.rawData()) != blockHash:
          return err("Data is not matching hash, number " & $blockData.number)

      block:
        let contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: contentKeyType)

        res.add((contentKey, @(rlp.rawData())))
        rlp.skipElem()

      block:
        let contentKey = ContentKey(
          contentType: blockBody,
          blockBodyKey: contentKeyType)

        # Note: Temporary until the data format gets changed.
        let blockBody = BlockBody(
          transactions: rlp.read(seq[Transaction]),
          uncles: rlp.read(seq[BlockHeader]))
        let rlpdata = encode(blockBody)

        res.add((contentKey, rlpdata))
        # res.add((contentKey, @(rlp.rawData())))
        # rlp.skipElem()

      # Note: No receipts yet in the data set
      # block:
        # let contentKey = ContentKey(
        #   contentType: receipts,
        #   receiptsKey: contentKeyType)

        # res.add((contentKey, @(rlp.rawData())))
        # rlp.skipElem()

    except RlpError as e:
      return err("Invalid rlp data, number " & $blockData.number & ": " & e.msg)

    ok(res)
  else:
    err("Item is not a valid rlp list, number " & $blockData.number)

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
      rlpFromHex(blockData.rlp)
    except ValueError as e:
      return err("Invalid hex for rlp block data, number " &
        $blockData.number & ": " & e.msg)

  if rlp.enterList():
    try:
      return ok(rlp.read(BlockHeader))
    except RlpError as e:
      return err("Invalid header, number " & $blockData.number & ": " & e.msg)
  else:
    return err("Item is not a valid rlp list, number " & $blockData.number)

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

      await p.neighborhoodGossip(keys, content)

  for i in 0 ..< concurrentGossips:
    gossipWorkers.add(gossipWorker(p))

  let blockData = readBlockDataTable(dataFile)

  if blockData.isOk():
    for b in blocks(blockData.get(), verify):
      for value in b:
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

      await p.neighborhoodGossip(ContentKeysList(@[encode(value[0])]), value[1])

    return ok()
  else:
    return err(blockDataTable.error)
