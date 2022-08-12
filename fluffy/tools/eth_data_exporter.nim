# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Tool to download chain history data from local node, and save it to the json
# file or sqlite database.
# In case of json:
# Block data is stored as it gets transmitted over the wire and as defined here:
#  https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#content-keys-and-values
#
# Json file has following format:
# {
#   "hexEncodedBlockHash: {
#     "header": "the rlp encoded block header as a hex string"
#     "body": "the SSZ encoded container of transactions and uncles as a hex string"
#     "receipts: "The SSZ encoded list of the receipts as a hex string"
#     "number": "block number"
#   },
#   ...,
#   ...,
# }
# In case of sqlite:
# Data is saved in a format friendly to history network i.e one table with 3
# columns: contentid, contentkey, content.
# Such format enables queries to quickly find content in range of some node
# which makes it possible to offer content to nodes in bulk.
#
# When using geth as client to download receipts from, be aware that you will
# have to set the number of blocks to maintain the transaction index for to
# unlimited if you want access to all transactions/receipts.
# e.g: `./build/bin/geth --ws --txlookuplimit=0`
#

{.push raises: [Defect].}

import
  std/[json, typetraits, strutils, os],
  confutils,
  stew/[byteutils, io2],
  json_serialization,
  faststreams, chronicles,
  eth/[common, rlp], chronos,
  eth/common/eth_types_json_serialization,
  json_rpc/rpcclient,
  ../seed_db,
  ../../premix/[downloader, parser],
  ../network/history/[history_content, accumulator]

# Need to be selective due to the `Block` type conflict from downloader
from ../network/history/history_network import encode

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "EthData"
  elif defined(macosx):
    "Library" / "Application Support" / "EthData"
  else:
    ".cache" / "ethData"

  getHomeDir() / dataDir

const
  defaultDataDirDesc = defaultDataDir()
  defaultBlockFileName = "eth-block-data"
  defaultAccumulatorFileName = "eth-accumulator.json"

type
  ExporterCmd* = enum
    exportBlockData
    exportAccumulatorData

  StorageMode* = enum
    Json, Db

  ExporterConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      defaultValueDesc: $LogLevel.INFO
      desc: "Sets the log level"
      name: "log-level" .}: LogLevel
    initialBlock* {.
      desc: "Number of the first block which should be downloaded"
      defaultValue: 0
      name: "initial-block" .}: uint64
    endBlock* {.
      desc: "Number of the last block which should be downloaded"
      defaultValue: 0
      name: "end-block" .}: uint64
    dataDir* {.
      desc: "The directory where generated data files will be exported to"
      defaultValue: defaultDataDir()
      defaultValueDesc: $defaultDataDirDesc
      name: "data-dir" .}: OutDir
    case cmd* {.
      command
      defaultValue: exportBlockData .}: ExporterCmd
    of exportBlockData:
      fileName* {.
        desc: "File name (minus extension) where block data will be exported to"
        defaultValue: defaultBlockFileName
        defaultValueDesc: $defaultBlockFileName
        name: "file-name" .}: string
      storageMode* {.
        desc: "Storage mode of block data export"
        defaultValue: Json
        name: "storage-mode" .}: StorageMode
      headersOnly* {.
        desc: "Only export the headers instead of full blocks and receipts"
        defaultValue: false
        name: "headers-only" .}: bool
    of exportAccumulatorData:
      accumulatorFileName* {.
        desc: "File to which the serialized accumulator data is written"
        defaultValue: defaultAccumulatorFileName
        defaultValueDesc: $defaultAccumulatorFileName
        name: "accumulator-file-name" .}: string

  HeaderRecord = object
    header: string
    number: uint64

  BlockRecord = object
    header: string
    body: string
    receipts: string
    number: uint64

  AccumulatorRecord = object
    accumulatorHash: string
    maxBlockNumber: uint64
    accumulator: string

proc parseCmdArg*(T: type StorageMode, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
  if p == "db":
    return Db
  elif p == "json":
    return Json
  else:
    let msg = "Provided mode: " & p & " is not a valid. Should be `json` or `db`"
    raise newException(ConfigurationError, msg)

proc completeCmdArg*(T: type StorageMode, val: TaintedString): seq[string] =
  return @[]

proc writeHeaderRecord(
    writer: var JsonWriter, header: BlockHeader)
    {.raises: [IOError, Defect].} =
  let
    dataRecord = HeaderRecord(
      header: rlp.encode(header).to0xHex(),
      number: header.blockNumber.truncate(uint64))

    headerHash = to0xHex(rlpHash(header).data)

  writer.writeField(headerHash, dataRecord)

proc writeBlockRecord(
    writer: var JsonWriter, blck: Block)
    {.raises: [IOError, Defect].} =
  let
    dataRecord = BlockRecord(
      header: rlp.encode(blck.header).to0xHex(),
      body: encode(blck.body).to0xHex(),
      receipts: encode(blck.receipts).to0xHex(),
      number: blck.header.blockNumber.truncate(uint64))

    headerHash = to0xHex(rlpHash(blck.header).data)

  writer.writeField(headerHash, dataRecord)

proc writeAccumulatorRecord(
    writer: var JsonWriter, accumulator: Accumulator)
    {.raises: [IOError, Defect].} =
  let
    maxBlockNumber =
      accumulator.historicalEpochs.len() * epochSize +
      accumulator.currentEpoch.len()
    accumulatorHash = hash_tree_root(accumulator).data.to0xHex()

    accumulatorRecord = AccumulatorRecord(
      accumulatorHash: accumulatorHash,
      maxBlockNumber: uint64(maxBlockNumber),
      accumulator: SSZ.encode(accumulator).to0xHex())

  writer.writeField("accumulator", accumulatorRecord)

proc writeEpochAccumulatorRecord(
    writer: var JsonWriter, accumulator: EpochAccumulator)
    {.raises: [IOError, Defect].} =
  writer.writeField("epochAccumulator", SSZ.encode(accumulator).to0xHex())

proc downloadHeader(client: RpcClient, i: uint64): BlockHeader =
  let blockNumber = u256(i)
  try:
    let jsonHeader = requestHeader(blockNumber, some(client))
    parseBlockHeader(jsonHeader)
  except CatchableError as e:
    fatal "Error while requesting BlockHeader", error = e.msg, number = i
    quit 1

proc downloadBlock(i: uint64, client: RpcClient): Block =
  let num = u256(i)
  try:
    return requestBlock(num, flags = {DownloadReceipts}, client = some(client))
  except CatchableError as e:
    fatal "Error while requesting Block", error = e.msg, number = i
    quit 1

proc createAndOpenFile(dataDir: string, fileName: string): OutputStreamHandle =
  # Creates directory and file, if file already exists
  # program is aborted with info to user, to avoid losing data
  let fileName: string =
    if not filename.endsWith(".json"):
      filename & ".json"
    else:
      filename

  let filePath = dataDir / fileName

  if isFile(filePath):
    fatal "File under provided path already exists and would be overwritten",
      path = filePath
    quit 1

  let res = createPath(dataDir)
  if res.isErr():
    fatal "Error occurred while creating directory",
      error = ioErrorMsg(res.error)
    quit 1

  try:
    return fileOutput(filePath)
  except IOError as e:
    fatal "Error occurred while opening the file", error = e.msg
    quit 1

proc writeHeadersToJson(config: ExporterConf, client: RpcClient) =
  let fh = createAndOpenFile(string config.dataDir, string config.fileName)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.beginRecord()
    for i in config.initialBlock..config.endBlock:
      let blck = client.downloadHeader(i)
      writer.writeHeaderRecord(blck)
      if ((i - config.initialBlock) mod 8192) == 0 and i != config.initialBlock:
        info "Downloaded 8192 new block headers", currentHeader = i
    writer.endRecord()
    info "File successfully written", path = config.dataDir / config.fileName
  except IOError as e:
    fatal "Error occured while writing to file", error = e.msg
    quit 1
  finally:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

proc writeBlocksToJson(config: ExporterConf, client: RpcClient) =
  let fh = createAndOpenFile(string config.dataDir, string config.fileName)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.beginRecord()
    for i in config.initialBlock..config.endBlock:
      let blck = downloadBlock(i, client)
      writer.writeBlockRecord(blck)
      if ((i - config.initialBlock) mod 8192) == 0 and i != config.initialBlock:
        info "Downloaded 8192 new blocks", currentBlock = i
    writer.endRecord()
    info "File successfully written", path = config.dataDir / config.fileName
  except IOError as e:
    fatal "Error occured while writing to file", error = e.msg
    quit 1
  finally:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

proc writeBlocksToDb(config: ExporterConf, client: RpcClient) =
  let db = SeedDb.new(distinctBase(config.dataDir), config.filename)

  defer:
    db.close()

  for i in config.initialBlock..config.endBlock:
    let
      blck = downloadBlock(i, client)
      blockHash = blck.header.blockHash()
      contentKeyType = BlockKey(chainId: 1, blockHash: blockHash)
      headerKey = encode(ContentKey(
        contentType: blockHeader, blockHeaderKey: contentKeyType))
      bodyKey = encode(ContentKey(
        contentType: blockBody, blockBodyKey: contentKeyType))
      receiptsKey = encode(
        ContentKey(contentType: receipts, receiptsKey: contentKeyType))

    db.put(headerKey.toContentId(), headerKey.asSeq(), rlp.encode(blck.header))

    # No need to seed empty lists into database
    if len(blck.body.transactions) > 0 or len(blck.body.uncles) > 0:
      let body = encode(blck.body)
      db.put(bodyKey.toContentId(), bodyKey.asSeq(), body)

    if len(blck.receipts) > 0:
      let receipts = encode(blck.receipts)
      db.put(receiptsKey.toContentId(), receiptsKey.asSeq(), receipts)

  info "Data successfuly written to db"

proc writeAccumulatorToJson(
    dataDir: string, fileName: string, accumulator: Accumulator) =
  let fh = createAndOpenFile(dataDir, fileName)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.beginRecord()
    writer.writeAccumulatorRecord(accumulator)
    writer.endRecord()
    info "File successfully written", path = dataDir / fileName
  except IOError as e:
    fatal "Error occured while writing to file", error = e.msg
    quit 1
  finally:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

proc writeEpochAccumulatorToJson(
    dataDir: string, fileName: string, accumulator: EpochAccumulator) =
  let fh = createAndOpenFile(dataDir, fileName)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.beginRecord()
    writer.writeEpochAccumulatorRecord(accumulator)
    writer.endRecord()
    info "File successfully written", path = dataDir / fileName
  except IOError as e:
    fatal "Error occured while writing to file", error = e.msg
    quit 1
  finally:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occured while closing file", error = e.msg
      quit 1

proc exportBlocks(config: ExporterConf, client: RpcClient) =
  case config.storageMode
  of Json:
    if config.headersOnly:
      writeHeadersToJson(config, client)
    else:
      writeBlocksToJson(config, client)
  of Db:
    if config.headersOnly:
      fatal "Db mode not available for headers only"
      quit 1
    else:
      writeBlocksToDb(config, client)

when isMainModule:
  {.pop.}
  let config = ExporterConf.load()
  {.push raises: [Defect].}

  setLogLevel(config.logLevel)

  if (config.endBlock < config.initialBlock):
    fatal "Initial block number should be smaller than end block number",
      initialBlock = config.initialBlock,
      endBlock = config.endBlock
    quit 1

  var client: RpcClient

  try:
    let c = newRpcWebSocketClient()
    # TODO: Hardcoded to the default geth ws address. This should become
    # a configurable cli option
    waitFor c.connect("ws://127.0.0.1:8546")
    client = c
  except CatchableError as e:
    fatal "Error while connecting to data provider", error = e.msg
    quit 1

  case config.cmd
  of ExporterCmd.exportBlockData:
    try:
      exportBlocks(config, client)
    finally:
      waitFor client.close()

  of ExporterCmd.exportAccumulatorData:
    var headers: seq[BlockHeader]
    for i in config.initialBlock..config.endBlock:
      let header = client.downloadHeader(i)
      headers.add(header)
      if ((i - config.initialBlock) mod 8192) == 0 and i != config.initialBlock:
        info "Downloaded 8192 new block headers", currentBlock = i

    waitFor client.close()

    info "Building the accumulator"
    let accumulator = buildAccumulator(headers)
    writeAccumulatorToJson(
      string config.dataDir, string config.accumulatorFileName, accumulator)

    let epochAccumulators = buildAccumulatorData(headers)

    for i, epochAccumulator in epochAccumulators:
      writeEpochAccumulatorToJson(
        string config.dataDir, "eth-epoch-accumulator_" & $i & ".json",
        epochAccumulator[1])
