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

proc readBlockData*(dataFile: string): Result[BlockDataTable, string] =
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

iterator blocks*(
    blockData: BlockDataTable, verify = false): seq[(ContentKey, seq[byte])] =
  for k,v in blockData:
    var res: seq[(ContentKey, seq[byte])]

    var rlp =
      try:
        rlpFromHex(v.rlp)
      except ValueError as e:
        error "Invalid hex for rlp data", error = e.msg, number = v.number
        continue

    # The data is currently formatted as an rlp encoded `EthBlock`, thus
    # containing header, txs and uncles: [header, txs, uncles]. No receipts are
    # available.
    # TODO: Change to format to rlp data as it gets stored and send over the
    # network over the network. I.e. [header, [txs, uncles], receipts]
    if rlp.enterList():
      var blockHash: BlockHash
      try:
        blockHash.data = hexToByteArray[sizeof(BlockHash)](k)
      except ValueError as e:
        error "Invalid hex for block hash", error = e.msg, number = v.number
        continue

      let contentKeyType =
        ContentKeyType(chainId: 1'u16, blockHash: blockHash)

      try:
        # If wanted the hash for the corresponding header can be verified
        if verify:
          if keccak256.digest(rlp.rawData()) != blockHash:
            error "Data is not matching hash, skipping", number = v.number
            continue

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
          echo rlpdata.toHex()
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
        error "Invalid rlp data", number = v.number, error = e.msg
        continue

      yield res
    else:
      error "Item is not a valid rlp list", number = v.number

proc populateHistoryDb*(
    db: ContentDB, dataFile: string, verify = false): Result[void, string] =
  let blockData = ? readBlockData(dataFile)

  for b in blocks(blockData, verify):
    for value in b:
      # Note: This is the slowest part due to the hashing that takes place.
      db.put(history_content.toContentId(value[0]), value[1])

  ok()

proc propagateHistoryDb*(
    p: PortalProtocol, dataFile: string, verify = false):
    Future[Result[void, string]] {.async.} =
  let blockData = readBlockData(dataFile)

  if blockData.isOk():
    for b in blocks(blockData.get(), verify):
      for value in b:
        # Note: This is the slowest part due to the hashing that takes place.
        p.contentDB.put(history_content.toContentId(value[0]), value[1])

        # TODO: This call will get the content we just stored in the db, so it
        # might be an improvement to directly pass it.
        await p.neighborhoodGossip(ContentKeysList(@[encode(value[0])]))
    return ok()
  else:
    return err(blockData.error)
