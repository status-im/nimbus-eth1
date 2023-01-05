# Nimbus - Portal Network
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_serialization, json_serialization/std/tables,
  stew/[byteutils, io2, results], chronicles,
  eth/[rlp, common/eth_types],
  ../../nimbus/common/[chain_config, genesis],
  ../network/history/[history_content, accumulator]

export results, tables

# Helper calls to read/write history data from/to json files.
# Format is currently unspecified and likely to change.

# Reading JSON history data

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

proc readJsonType*(dataFile: string, T: type): Result[T, string] =
  let data = readAllFile(dataFile)
  if data.isErr(): # TODO: map errors
    return err("Failed reading data-file")

  let decoded =
    try:
      Json.decode(data.get(), T)
    except SerializationError as e:
      return err("Failed decoding json data-file: " & e.msg)

  ok(decoded)

iterator blockHashes*(blockData: BlockDataTable): BlockHash =
  for k, v in blockData:
    var blockHash: BlockHash
    try:
      blockHash.data = hexToByteArray[sizeof(BlockHash)](k)
    except ValueError as e:
      error "Invalid hex for block hash", error = e.msg, number = v.number
      continue

    yield blockHash

func readBlockData*(
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
    BlockKey(blockHash: blockHash)

  try:
    # If wanted the hash for the corresponding header can be verified
    if verify:
      if keccakHash(blockData.header.hexToSeqByte()) != blockHash:
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
  for k, v in blockData:
    let res = readBlockData(k, v, verify)

    if res.isOk():
      yield res.get()
    else:
      error "Failed reading block from block data", error = res.error

iterator blocksContent*(
    blockData: BlockDataTable, verify = false): (ContentId, seq[byte], seq[byte]) =
  for b in blocks(blockData, verify):
    for value in b:
      if len(value[1]) > 0:
        let ckBytes = history_content.encode(value[0])
        let contentId = history_content.toContentId(ckBytes)
        yield (contentId, ckBytes.asSeq(), value[1])

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

func readHeaderData*(
    hash: string, blockData: BlockData, verify = false):
    Result[(ContentKey, seq[byte]), string] =
  var blockHash: BlockHash
  try:
    blockHash.data = hexToByteArray[sizeof(BlockHash)](hash)
  except ValueError as e:
    return err("Invalid hex for blockhash, number " &
      $blockData.number & ": " & e.msg)

  let contentKeyType =
    BlockKey(blockHash: blockHash)

  try:
    # If wanted the hash for the corresponding header can be verified
    if verify:
      if keccakHash(blockData.header.hexToSeqByte()) != blockHash:
        return err("Data is not matching hash, number " & $blockData.number)

    let contentKey = ContentKey(
      contentType: blockHeader,
      blockHeaderKey: contentKeyType)

    let res = (contentKey, blockData.header.hexToSeqByte())
    return ok(res)

  except ValueError as e:
    return err("Invalid hex data, number " & $blockData.number & ": " & e.msg)

iterator headers*(
    blockData: BlockDataTable, verify = false): (ContentKey, seq[byte]) =
  for k, v in blockData:
    let res = readHeaderData(k, v, verify)

    if res.isOk():
      yield res.get()
    else:
      error "Failed reading header from block data", error = res.error

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


# Writing JSON history data

type
  HeaderRecord* = object
    header: string
    number: uint64

  BlockRecord* = object
    header: string
    body: string
    receipts: string
    number: uint64

proc writeHeaderRecord*(
    writer: var JsonWriter, header: BlockHeader)
    {.raises: [IOError, Defect].} =
  let
    dataRecord = HeaderRecord(
      header: rlp.encode(header).to0xHex(),
      number: header.blockNumber.truncate(uint64))

    headerHash = to0xHex(rlpHash(header).data)

  writer.writeField(headerHash, dataRecord)

proc writeBlockRecord*(
    writer: var JsonWriter,
    header: BlockHeader, body: BlockBody, receipts: seq[Receipt])
    {.raises: [IOError, Defect].} =
  let
    dataRecord = BlockRecord(
      header: rlp.encode(header).to0xHex(),
      body: encode(body).to0xHex(),
      receipts: encode(receipts).to0xHex(),
      number: header.blockNumber.truncate(uint64))

    headerHash = to0xHex(rlpHash(header).data)

  writer.writeField(headerHash, dataRecord)
