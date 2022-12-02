# Nimbus - Portal Network
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  json_serialization, json_serialization/std/tables,
  stew/[byteutils, io2, results], chronicles,
  eth/[rlp, common/eth_types],
  ncli/e2store,
  ../../nimbus/common/[chain_config, genesis],
  ../network/history/[history_content, accumulator]

export results, tables

# Helper calls to parse history data from json files. Format currently
# unspecified and likely to change.
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

proc toString*(v: IoErrorCode): string =
  try: ioErrorMsg(v)
  except Exception as e: raiseAssert e.msg

proc readAccumulator*(file: string): Result[FinishedAccumulator, string] =
  let encodedAccumulator = ? readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedAccumulator, FinishedAccumulator))
  except SszError as e:
    err("Failed decoding accumulator: " & e.msg)


proc readEpochAccumulator*(file: string): Result[EpochAccumulator, string] =
  let encodedAccumulator = ? readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedAccumulator, EpochAccumulator))
  except SszError as e:
    err("Decoding epoch accumulator failed: " & e.msg)

proc readEpochAccumulatorCached*(file: string): Result[EpochAccumulatorCached, string] =
  let encodedAccumulator = ? readAllFile(file).mapErr(toString)

  try:
    ok(SSZ.decode(encodedAccumulator, EpochAccumulatorCached))
  except SszError as e:
    err("Decoding epoch accumulator failed: " & e.msg)

const
  # Using the e2s format to store data, but without the specific structure
  # like in an era file, as we currently don't really need that.
  # See: https://github.com/status-im/nimbus-eth2/blob/stable/docs/e2store.md
  # Added one type for now, with numbers not formally specified.
  # Note:
  # Snappy compression for `ExecutionBlockHeaderRecord` only helps for the
  # first ~1M (?) block headers, after that there is no gain so we don't do it.
  ExecutionBlockHeaderRecord* = [byte 0xFF, 0x00]

proc readBlockHeaders*(file: string): Result[seq[BlockHeader], string] =
  let fh = ? openFile(file, {OpenFlags.Read}).mapErr(toString)
  defer: discard closeFile(fh)

  var data: seq[byte]
  var blockHeaders: seq[BlockHeader]
  while true:
    let header = readRecord(fh, data).valueOr:
      break

    if header.typ == ExecutionBlockHeaderRecord:
      let blockHeader =
        try:
          rlp.decode(data, BlockHeader)
        except RlpError as e:
          return err("Invalid block header in " & file & ": " & e.msg)

      blockHeaders.add(blockHeader)
    else:
      warn "Skipping record, not a block header", typ = toHex(header.typ)

  ok(blockHeaders)
