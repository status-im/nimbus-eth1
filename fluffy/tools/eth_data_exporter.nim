# Fluffy
# Copyright (c) 2022-2023 Status Research & Development GmbH
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

{.push raises: [].}

import
  std/[json, typetraits, strutils, strformat, os, uri],
  confutils,
  stew/[byteutils, io2],
  json_serialization,
  faststreams, chronicles,
  eth/[common, rlp], chronos,
  eth/common/eth_types_json_serialization,
  json_rpc/rpcclient,
  ncli/e2store,
  ../database/seed_db,
  ../../premix/[downloader, parser],
  ../network/history/[history_content, accumulator],
  ../eth_data/[history_data_json_store, history_data_ssz_e2s],
  eth_data_exporter/[exporter_conf, exporter_common, cl_data_exporter]

# Need to be selective due to the `Block` type conflict from downloader
from ../network/history/history_network import encode

chronicles.formatIt(IoErrorCode): $it

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

proc writeHeadersToJson(config: ExporterConf, client: RpcClient) =
  let fh = createAndOpenFile(string config.dataDir, string config.fileName)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s, pretty = true)
    writer.beginRecord()
    for i in config.startBlock..config.endBlock:
      let blck = client.downloadHeader(i)
      writer.writeHeaderRecord(blck)
      if ((i - config.startBlock) mod 8192) == 0 and i != config.startBlock:
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
    for i in config.startBlock..config.endBlock:
      let blck = downloadBlock(i, client)
      writer.writeBlockRecord(blck.header, blck.body, blck.receipts)
      if ((i - config.startBlock) mod 8192) == 0 and i != config.startBlock:
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
  let db = SeedDb.new(distinctBase(config.dataDir), config.fileName)

  defer:
    db.close()

  for i in config.startBlock..config.endBlock:
    let
      blck = downloadBlock(i, client)
      blockHash = blck.header.blockHash()
      contentKeyType = BlockKey(blockHash: blockHash)
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

proc exportBlocks(config: ExporterConf, client: RpcClient) =
  case config.storageMode
  of JsonStorage:
    if config.headersOnly:
      writeHeadersToJson(config, client)
    else:
      writeBlocksToJson(config, client)
  of DbStorage:
    if config.headersOnly:
      fatal "Db mode not available for headers only"
      quit 1
    else:
      writeBlocksToDb(config, client)

proc newRpcClient(web3Url: Web3Url): RpcClient =
  # TODO: I don't like this API. I think the creation of the RPC clients should
  # already include the URL. And then an optional connect may be necessary
  # depending on the protocol.
  let client: RpcClient =
    case web3Url.kind
    of HttpUrl:
      newRpcHttpClient()
    of WsUrl:
      newRpcWebSocketClient()

  client

proc connectRpcClient(
    client: RpcClient, web3Url: Web3Url):
    Future[Result[void, string]] {.async.} =
  case web3Url.kind
  of HttpUrl:
    try:
      await RpcHttpClient(client).connect(web3Url.url)
    except CatchableError as e:
      return err(e.msg)
  of WsUrl:
    try:
      await RpcWebSocketClient(client).connect(web3Url.url)
    except CatchableError as e:
      return err(e.msg)

when isMainModule:
  {.pop.}
  let config = ExporterConf.load()
  {.push raises: [].}

  setLogLevel(config.logLevel)

  let dataDir = config.dataDir.string
  if not isDir(dataDir):
    let res = createPath(dataDir)
    if res.isErr():
      fatal "Error occurred while creating data directory",
        dir = dataDir, error = ioErrorMsg(res.error)
      quit 1

  case config.cmd
  of ExporterCmd.history:
    case config.historyCmd
    of HistoryCmd.exportBlockData:
      let client = newRpcClient(config.web3Url)
      let connectRes = waitFor client.connectRpcClient(config.web3Url)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit 1

      if (config.endBlock < config.startBlock):
        fatal "Initial block number should be smaller than end block number",
          startBlock = config.startBlock,
          endBlock = config.endBlock
        quit 1

      try:
        exportBlocks(config, client)
      finally:
        waitFor client.close()

    of HistoryCmd.exportEpochHeaders:
      let client = newRpcClient(config.web3Url)
      let connectRes = waitFor client.connectRpcClient(config.web3Url)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit 1

      proc exportEpochHeaders(file: string, epoch: uint64): Result[void, string] =
        # Downloading headers from JSON RPC endpoint
        info "Requesting epoch headers", epoch
        var headers: seq[BlockHeader]
        for j in 0..<epochSize.uint64:
          debug "Requesting block", number = j
          let header = client.downloadHeader(epoch*epochSize + j)
          headers.add(header)

        let fh = ? openFile(file, {OpenFlags.Write, OpenFlags.Create}).mapErr(toString)
        defer: discard closeFile(fh)

        info "Writing headers to file", file
        for header in headers:
          discard ? fh.appendRecord(ExecutionBlockHeaderRecord, rlp.encode(header))

        ok()

      # TODO: Could make the JSON-RPC requests concurrent per epoch.
      # Batching would also be nice but our json-rpc does not support that:
      # https://geth.ethereum.org/docs/rpc/batch
      for i in config.startEpoch..config.endEpoch:
        let file = dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"

        if isFile(file):
          notice "Skipping epoch headers, file already exists", file
        else:
          let res = exportEpochHeaders(file, i)
          if res.isErr():
            error "Failed exporting epoch headers", file, error = res.error

      waitFor client.close()

    of HistoryCmd.verifyEpochHeaders:
      proc verifyEpochHeaders(file: string, epoch: uint64): Result[void, string] =
        let fh = ? openFile(file, {OpenFlags.Read}).mapErr(toString)
        defer: discard closeFile(fh)

        var data: seq[byte]
        while true:
          let header = readRecord(fh, data).valueOr:
            break

          if header.typ == ExecutionBlockHeaderRecord:
            let
              blockHeader =
                try:
                  rlp.decode(data, BlockHeader)
                except RlpError as e:
                  return err("Invalid block header: " & e.msg)

              headerHash = to0xHex(rlpHash(blockHeader).data)
            debug "Header decoded successfully",
              hash = headerHash, blockNumber = blockHeader.blockNumber
          else:
            warn "Skipping record, not a block header", typ = toHex(header.typ)

        ok()

      for i in config.startEpochVerify..config.endEpochVerify:
        let file = dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
        let res = verifyEpochHeaders(file, i)
        if res.isErr():
          error "Failed verifying epoch headers", file, error = res.error
        else:
          info "Successfully decoded epoch headers", file

    of HistoryCmd.exportAccumulatorData:
      # Lets first check if the accumulator file already exists before starting
      # to build it.
      let accumulatorFile = dataDir / config.accumulatorFileName
      if isFile(accumulatorFile):
        notice "Not building accumulator, file already exists",
          file = accumulatorFile
        quit 1

      # Lets verify if the necessary files exists before starting to build the
      # accumulator.
      for i in 0..<preMergeEpochs:
        let file = dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
        if not isFile(file):
          fatal "Required epoch headers file does not exist", file
          quit 1

      proc buildAccumulator(dataDir: string, writeEpochAccumulators = false):
          Result[FinishedAccumulator, string] =
        var accumulator: Accumulator
        for i in 0..<preMergeEpochs:
          let file =
            try: dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
            except ValueError as e: raiseAssert e.msg

          let fh = ? openFile(file, {OpenFlags.Read}).mapErr(toString)
          defer: discard closeFile(fh)

          var data: seq[byte]
          var count = 0'u64
          while true:
            let header = readRecord(fh, data).valueOr:
              break

            if header.typ == ExecutionBlockHeaderRecord:
              let blockHeader =
                try:
                  rlp.decode(data, BlockHeader)
                except RlpError as e:
                  return err("Invalid block header in " & file & ": " & e.msg)

              # Quick sanity check
              if blockHeader.blockNumber.truncate(uint64) != i*epochSize + count:
                fatal "Incorrect block headers in file", file = file,
                  blockNumber = blockHeader.blockNumber,
                  expectedBlockNumber = i*epochSize + count
                quit 1

              updateAccumulator(accumulator, blockHeader)

              # Note: writing away of epoch accumulators occurs 1 iteration before
              # updating the epoch accumulator, as the latter happens when passed
              # a header for the next epoch (or on finishing the epoch).
              if writeEpochAccumulators:
                if accumulator.currentEpoch.len() == epochSize or
                  blockHeader.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
                    let file =
                      try: dataDir / &"mainnet-epoch-accumulator-{i.uint64:05}.ssz"
                      except ValueError as e: raiseAssert e.msg
                    let res = io2.writeFile(file, SSZ.encode(accumulator.currentEpoch))
                    if res.isErr():
                      error "Failed writing epoch accumulator to file",
                        file, error = res.error
                    else:
                      notice "Succesfully wrote epoch accumulator to file", file

              if count == epochSize - 1:
                info "Updated an epoch", epoch = i
              count.inc()

              if blockHeader.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
                let finishedAccumulator = finishAccumulator(accumulator)
                info "Updated last epoch, finished building master accumulator",
                  epoch = i
                return ok(finishedAccumulator)
            else:
              warn "Skipping record, not a block header", typ = toHex(header.typ)

        err("Not enough headers provided to finish the accumulator")

      let accumulatorRes = buildAccumulator(dataDir, config.writeEpochAccumulators)
      if accumulatorRes.isErr():
        fatal "Could not build accumulator", error = accumulatorRes.error
        quit 1
      let accumulator = accumulatorRes.get()

      let res = io2.writeFile(accumulatorFile, SSZ.encode(accumulator))
      if res.isErr():
        error "Failed writing accumulator to file",
          file = accumulatorFile, error = res.error
        quit 1
      else:
        notice "Succesfully wrote master accumulator to file",
          file = accumulatorFile

    of HistoryCmd.printAccumulatorData:
      let file = dataDir / config.accumulatorFileNamePrint

      let res = readAccumulator(file)
      if res.isErr():
        fatal "Failed reading accumulator from file", error = res.error, file
        quit 1

      let
        accumulator = res.get()
        accumulatorRoot = hash_tree_root(accumulator)

      info "Accumulator decoded successfully",
        root = accumulatorRoot

      echo "Master Accumulator:"
      echo "-------------------"
      echo &"Root: {accumulatorRoot}"
      echo ""
      echo "Historical Epochs:"
      echo "------------------"
      echo "Epoch Root"
      for i, root in accumulator.historicalEpochs:
        echo &"{i.uint64:05} 0x{root.toHex()}"

    of HistoryCmd.exportHeaderRange:
      let client = newRpcClient(config.web3Url)
      let connectRes = waitFor client.connectRpcClient(config.web3Url)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit 1

      let
        startBlockNumber = config.startBlockNumber
        endBlockNumber = config.endBlockNumber

      if (endBlockNumber < startBlockNumber):
        fatal "Start block number should be smaller than end block number",
          startBlockNumber, endBlockNumber
        quit 1

      proc exportHeaders(
          file: string, startBlockNumber, endBlockNumber: uint64):
          Result[void, string] =
        # Downloading headers from JSON RPC endpoint
        info "Requesting headers", startBlockNumber, endBlockNumber
        var headers: seq[BlockHeader]
        for j in startBlockNumber..endBlockNumber:
          debug "Requesting block", number = j
          let header = client.downloadHeader(j)
          headers.add(header)

        let fh = ? openFile(
          file, {OpenFlags.Write, OpenFlags.Create}).mapErr(toString)
        defer: discard closeFile(fh)

        info "Writing headers to file", file
        for header in headers:
          discard ? fh.appendRecord(ExecutionBlockHeaderRecord, rlp.encode(header))

        ok()

      let file =
        try: dataDir / &"mainnet-headers-{startBlockNumber:05}-{endBlockNumber:05}.e2s"
        except ValueError as e: raiseAssert e.msg

      let res = exportHeaders(file, startBlockNumber, endBlockNumber)
      if res.isErr():
        fatal "Failed exporting headers", error = res.error
        quit 1

    of HistoryCmd.exportHeadersWithProof:
      let
        startBlockNumber = config.startBlockNumber2
        endBlockNumber = config.endBlockNumber2

      if (endBlockNumber < startBlockNumber):
        fatal "Start block number should be smaller than end block number",
          startBlockNumber, endBlockNumber
        quit 1

      let file = &"mainnet-headersWithProof-{startBlockNumber:05}-{endBlockNumber:05}.json"
      let fh = createAndOpenFile(string config.dataDir, file)

      var contentTable: JsonPortalContentTable
      for blockNumber in startBlockNumber..endBlockNumber:
        let
          epochIndex = getEpochIndex(blockNumber)
          epochHeadersFile =
            dataDir / &"mainnet-headers-epoch-{epochIndex:05}.e2s"
          epochAccumulatorFile =
            dataDir / &"mainnet-epoch-accumulator-{epochIndex:05}.ssz"

        let res = readBlockHeaders(epochHeadersFile)
        if res.isErr():
          error "Could not read headers epoch file", error = res.error
          quit 1

        let blockHeaders = res.get()

        let epochAccumulatorRes = readEpochAccumulatorCached(epochAccumulatorFile)
        if epochAccumulatorRes.isErr():
          error "Could not read epoch accumulator file", error = res.error
          quit 1

        let epochAccumulator = epochAccumulatorRes.get()

        let headerIndex = getHeaderRecordIndex(blockNumber, epochIndex)
        let header = blockHeaders[headerIndex]
        if header.isPreMerge():
          let headerWithProof = buildHeaderWithProof(header, epochAccumulator)
          if headerWithProof.isErr:
            error "Error building proof", error = headerWithProof.error
            quit 1

          let
            content = headerWithProof.get()
            contentKey = ContentKey(
              contentType: blockHeader,
              blockHeaderKey: BlockKey(blockHash: header.blockHash()))
            encodedContentKey = history_content.encode(contentKey)
            encodedContent = SSZ.encode(content)

          let portalContent = JsonPortalContent(
            content_key: encodedContentKey.asSeq().to0xHex(),
            content_value: encodedContent.to0xHex())

          contentTable[$blockNumber] = portalContent
        else:
          # TODO: Deal with writing post merge headers
          error "Not a pre merge header"
          quit 1

      writePortalContentToJson(fh, contentTable)

      try:
        fh.close()
      except IOError as e:
        fatal "Error occured while closing file", error = e.msg
        quit 1

  of ExporterCmd.beacon:
    let (cfg, forkDigests, _) = getBeaconData()

    case config.beaconCmd
    of BeaconCmd.exportLCBootstrap:
      waitFor exportLCBootstrapUpdate(
        config.restUrl, string config.dataDir,
        config.trustedBlockRoot,
        cfg, forkDigests)
    of BeaconCmd.exportLCUpdates:
      waitFor exportLCUpdates(
        config.restUrl, string config.dataDir,
        config.startPeriod, config.count,
        cfg, forkDigests)
    of BeaconCmd.exportLCFinalityUpdate:
      waitFor exportLCFinalityUpdate(
        config.restUrl, string config.dataDir, cfg, forkDigests)
    of BeaconCmd.exportLCOptimisticUpdate:
      waitFor exportLCOptimisticUpdate(
        config.restUrl, string config.dataDir, cfg, forkDigests)
