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
  eth/rlp,
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
    try:
      var blockHash: BlockHash
      blockHash.data = hexToByteArray[sizeof(BlockHash)](k)
      yield blockHash
    except ValueError as e:
      error "Invalid hex for block hash", error = e.msg, number = v.number

iterator blockHeaders*(
    blockData: BlockDataTable, verify = false): (ContentKey, seq[byte]) =
  for k,v in blockData:
    try:
      var rlp = rlpFromHex(v.rlp)

      if rlp.enterList():
        # List that contains 3 items: Block header, body and receipts.
        # Only make block header available for now.
        # When we want others, can use `rlp.skipElem()` and `rlp.rawData()`.

        # Prepare content key
        var blockHash: BlockHash
        blockHash.data = hexToByteArray[sizeof(BlockHash)](k)

        let contentKey = ContentKey(
          contentType: blockHeader,
          blockHeaderKey: ContentKeyType(chainId: 1'u16, blockHash: blockHash))

        # If wanted we can verify the hash for the corresponding header
        if verify:
          if keccak256.digest(rlp.rawData()) != blockHash:
            error "Data is not matching hash, skipping"
            continue

        yield (contentKey, @(rlp.rawData()))
    except CatchableError as e:
      error "Failed decoding block hash or data", error = e.msg,
        number = v.number

proc populateHistoryDb*(
    db: ContentDB, dataFile: string, verify = false): Result[void, string] =
  let blockData = ? readBlockData(dataFile)

  for k,v in blockHeaders(blockData, verify):
    # Note: This is the slowest part due to the hashing that takes place.
    db.put(history_content.toContentId(k), v)

  ok()

proc propagateHistoryDb*(
    p: PortalProtocol, dataFile: string, verify = false):
    Future[Result[void, string]] {.async.} =
  let blockData = readBlockData(dataFile)

  if blockData.isOk():
    for k,v in blockHeaders(blockData.get(), verify):
      # Note: This is the slowest part due to the hashing that takes place.
      p.contentDB.put(history_content.toContentId(k), v)

      # TODO: This call will get the content we just stored in the db, so it
      # might be an improvement to directly pass it.
      await p.neighborhoodGossip(ContentKeysList(@[encode(k)]))
    return ok()
  else:
    return err(blockData.error)
