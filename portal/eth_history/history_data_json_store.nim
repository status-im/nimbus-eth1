# Nimbus - Portal Network
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  json_serialization,
  json_serialization/std/tables,
  results,
  stew/[byteutils, io2],
  chronicles,
  eth/common/[hashes, blocks, receipts, headers_rlp],
  ../../execution_chain/common/[chain_config, genesis],
  ../network/history/history_content,
  ./block_proofs/historical_hashes_accumulator

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

func readBlockHeader*(blockData: BlockData): Result[Header, string] =
  var rlp =
    try:
      rlpFromHex(blockData.header)
    except ValueError as e:
      return err(
        "Invalid hex for rlp block data, number " & $blockData.number & ": " & e.msg
      )

  try:
    return ok(rlp.read(Header))
  except RlpError as e:
    return err("Invalid header, number " & $blockData.number & ": " & e.msg)

proc getGenesisHeader*(id: NetworkId = MainNet): Header =
  let params =
    try:
      networkParams(id)
    except ValueError, RlpError:
      debugEcho getCurrentException()[]
      raise (ref Defect)(msg: "Network parameters should be valid")

  toGenesisHeader(params)

# Reading JSON Portal content and content keys

type
  JsonPortalContent* = object
    content_key*: string
    content_value*: string

  JsonPortalContentTable* = OrderedTable[string, JsonPortalContent]

proc toString(v: IoErrorCode): string =
  try:
    ioErrorMsg(v)
  except Exception as e:
    raiseAssert e.msg

proc readJsonType*(dataFile: string, T: type): Result[T, string] =
  let data = ?readAllFile(dataFile).mapErr(toString)

  let decoded =
    try:
      Json.decode(data, T)
    except SerializationError as e:
      return err("Failed decoding json data-file: " & e.msg)

  ok(decoded)

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

proc writeHeaderRecord*(writer: var JsonWriter, header: Header) {.raises: [IOError].} =
  let
    dataRecord =
      HeaderRecord(header: rlp.encode(header).to0xHex(), number: header.number)

    headerHash = to0xHex(computeRlpHash(header).data)

  writer.writeField(headerHash, dataRecord)

proc writeBlockRecord*(
    writer: var JsonWriter, header: Header, body: BlockBody, receipts: seq[Receipt]
) {.raises: [IOError].} =
  let
    dataRecord = BlockRecord(
      header: rlp.encode(header).to0xHex(),
      body: encode(body).to0xHex(),
      receipts: encode(receipts).to0xHex(),
      number: header.number,
    )

    headerHash = to0xHex(computeRlpHash(header).data)

  writer.writeField(headerHash, dataRecord)
