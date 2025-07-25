# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Tool to download chain history data from full node and export it.

{.push raises: [].}

import
  std/[json, typetraits, strutils, strformat, os, uri],
  confutils,
  stew/[byteutils, io2],
  json_serialization,
  faststreams,
  chronicles,
  chronos,
  eth/rlp,
  eth/common/headers_rlp,
  eth/common/eth_types_json_serialization,
  json_rpc/rpcclient,
  snappy,
  ncli/e2store,
  ../network/legacy_history/
    [history_content, validation/block_proof_historical_hashes_accumulator],
  ../eth_data/[history_data_json_store, history_data_ssz_e2s, era1],
  eth_data_exporter/[exporter_conf, exporter_common, cl_data_exporter, el_data_exporter]

# Need to be selective due to the `Block` type conflict from downloader
from ../network/legacy_history/history_network import encode

chronicles.formatIt(IoErrorCode):
  $it

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
    client: RpcClient, web3Url: Web3Url
): Future[Result[void, string]] {.async.} =
  case web3Url.kind
  of HttpUrl:
    try:
      await RpcHttpClient(client).connect(web3Url.url)
      ok()
    except CatchableError as e:
      return err(e.msg)
  of WsUrl:
    try:
      await RpcWebSocketClient(client).connect(web3Url.url)
      ok()
    except CatchableError as e:
      return err(e.msg)

proc cmdExportEra1(config: ExporterConf) =
  let client = newRpcClient(config.web3Url)
  try:
    let connectRes = waitFor client.connectRpcClient(config.web3Url)
    if connectRes.isErr():
      fatal "Failed connecting to JSON-RPC client", error = connectRes.error
      quit QuitFailure
  except CatchableError as e:
    # TODO: Add async raises to get rid of this.
    fatal "Failed connecting to JSON-RPC client", error = e.msg
    quit QuitFailure

  var era = Era1(config.era)
  while config.eraCount == 0 or era < Era1(config.era) + config.eraCount:
    defer:
      era += 1

    let
      startNumber = era.startNumber()
      endNumber = era.endNumber()

    if startNumber >= mergeBlockNumber:
      info "Stopping era as it is after the merge"
      break

    var accumulatorRoot = default(Digest)
    let tmpName = era1FileName("mainnet", era, default(Digest)) & ".tmp"

    info "Writing era1", tmpName

    var completed = false
    block writeFileBlock:
      let e2 =
        openFile(tmpName, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).get()
      defer:
        discard closeFile(e2)

      # TODO: Not checking the result of init, update or finish here, as all
      # error cases are fatal. But maybe we could throw proper errors still.
      var group = Era1Group.init(e2, startNumber).get()

      # Header records to build the HistoricalHashesAccumulator root
      var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
      for blockNumber in startNumber .. endNumber:
        let
          (header, body, totalDifficulty) = (
            waitFor noCancel(client.getBlockByNumber(blockNumber))
          ).valueOr:
            error "Failed retrieving block, skip creation of era1 file",
              blockNumber, error
            break writeFileBlock
          receipts = (waitFor noCancel(client.getReceiptsByNumber(blockNumber))).valueOr:
            error "Failed retrieving receipts, skip creation of era1 file",
              blockNumber, error
            break writeFileBlock

        headerRecords.add(
          historical_hashes_accumulator.HeaderRecord(
            blockHash: header.computeRlpHash(), totalDifficulty: totalDifficulty
          )
        )

        group.update(e2, blockNumber, header, body, receipts, totalDifficulty).get()

      accumulatorRoot = getEpochRecordRoot(headerRecords)

      group.finish(e2, accumulatorRoot, endNumber).get()
      completed = true
    if completed:
      let name = era1FileName("mainnet", era, accumulatorRoot)
      # We cannot check for the exact file any earlier as we need to know the
      # HistoricalHashesAccumulator root.
      # TODO: Could scan for file with era number in it.
      if isFile(name):
        info "Era1 file already exists", era, name
        if (let e = io2.removeFile(tmpName); e.isErr):
          warn "Failed to clean up tmp era1 file", tmpName, error = e.error
        continue

      try:
        moveFile(tmpName, name)
      except Exception as e: # TODO
        warn "Failed to rename era1 file to its final name",
          name, tmpName, error = e.msg

      info "Writing era1 completed", name
    else:
      error "Failed creating the era1 file", era
      if (let e = io2.removeFile(tmpName); e.isErr):
        warn "Failed to clean up incomplete era1 file", tmpName, error = e.error

proc cmdVerifyEra1(config: ExporterConf) =
  let f = Era1File.open(config.era1FileName).valueOr:
    warn "Failed to open era file", error = error
    quit QuitFailure
  defer:
    close(f)

  let root = f.verify.valueOr:
    warn "Verification of era file failed", error = error
    quit QuitFailure

  notice "Era1 file succesfully verified",
    accumulatorRoot = root.data.to0xHex(), file = config.era1FileName

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
      quit QuitFailure

  case config.cmd
  of ExporterCmd.history:
    case config.historyCmd
    of HistoryCmd.exportBlockData:
      let client = newRpcClient(config.web3Url)
      let connectRes = waitFor client.connectRpcClient(config.web3Url)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit QuitFailure

      defer:
        waitFor client.close()

      let fileName = dataDir / "block-data-" & $config.blockNumber & ".yaml"
      (waitFor client.exportBlock(config.blockNumber, fileName)).isOkOr:
        fatal "Failed exporting block data",
          blockNumber = config.blockNumber, error = error
        quit QuitFailure

      info "Block data exported successfully", fileName = fileName
    of HistoryCmd.exportEpochHeaders:
      let client = newRpcClient(config.web3Url)
      let connectRes = waitFor client.connectRpcClient(config.web3Url)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit QuitFailure

      proc exportEpochHeaders(file: string, epoch: uint64): Result[void, string] =
        # Downloading headers from JSON RPC endpoint
        info "Requesting epoch headers", epoch
        var headers: seq[headers.Header]
        for j in 0 ..< EPOCH_SIZE.uint64:
          info "Requesting block", number = j
          let header = (
            waitFor noCancel(client.getHeaderByNumber(epoch * EPOCH_SIZE + j))
          ).valueOr:
            fatal "Failed retrieving block header",
              blockNumber = epoch * EPOCH_SIZE + j, error
            quit QuitFailure
          headers.add(header)

        let fh = ?openFile(file, {OpenFlags.Write, OpenFlags.Create}).mapErr(toString)
        defer:
          discard closeFile(fh)

        info "Writing headers to file", file
        for header in headers:
          discard ?fh.appendRecord(ExecutionBlockHeaderRecord, rlp.encode(header))

        ok()

      # TODO: Could make the JSON-RPC requests concurrent per epoch.
      # Batching would also be nice but our json-rpc does not support that:
      # https://geth.ethereum.org/docs/rpc/batch
      for i in config.startEpoch .. config.endEpoch:
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
        let fh = ?openFile(file, {OpenFlags.Read}).mapErr(toString)
        defer:
          discard closeFile(fh)

        var data: seq[byte]
        while true:
          let header = readRecord(fh, data).valueOr:
            break

          if header.typ == ExecutionBlockHeaderRecord:
            let
              blockHeader =
                try:
                  rlp.decode(data, headers.Header)
                except RlpError as e:
                  return err("Invalid block header: " & e.msg)

              headerHash = to0xHex(computeRlpHash(blockHeader).data)
            debug "Header decoded successfully",
              hash = headerHash, blockNumber = blockHeader.number
          else:
            warn "Skipping record, not a block header", typ = toHex(header.typ)

        ok()

      for i in config.startEpochVerify .. config.endEpochVerify:
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
        notice "Not building HistoricalHashesAccumulator, file already exists",
          file = accumulatorFile
        quit QuitFailure

      # Lets verify if the necessary files exists before starting to build the
      # accumulator.
      for i in 0 ..< preMergeEpochs:
        let file = dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
        if not isFile(file):
          fatal "Required epoch headers file does not exist", file
          quit QuitFailure

      proc buildAccumulator(
          dataDir: string, writeEpochRecords = false
      ): Result[FinishedHistoricalHashesAccumulator, string] =
        var accumulator: HistoricalHashesAccumulator
        for i in 0 ..< preMergeEpochs:
          let file =
            try:
              dataDir / &"mainnet-headers-epoch-{i.uint64:05}.e2s"
            except ValueError as e:
              raiseAssert e.msg

          let fh = ?openFile(file, {OpenFlags.Read}).mapErr(toString)
          defer:
            discard closeFile(fh)

          var data: seq[byte]
          var count = 0'u64
          while true:
            let header = readRecord(fh, data).valueOr:
              break

            if header.typ == ExecutionBlockHeaderRecord:
              let blockHeader =
                try:
                  rlp.decode(data, headers.Header)
                except RlpError as e:
                  return err("Invalid block header in " & file & ": " & e.msg)

              # Quick sanity check
              if blockHeader.number != i * EPOCH_SIZE + count:
                fatal "Incorrect block headers in file",
                  file = file,
                  blockNumber = blockHeader.number,
                  expectedBlockNumber = i * EPOCH_SIZE + count
                quit QuitFailure

              updateAccumulator(accumulator, blockHeader)

              # Note: writing away of epoch accumulators occurs 1 iteration before
              # updating the epoch accumulator, as the latter happens when passed
              # a header for the next epoch (or on finishing the epoch).
              if writeEpochRecords:
                if accumulator.currentEpoch.len() == EPOCH_SIZE or
                    blockHeader.number == mergeBlockNumber - 1:
                  let file =
                    try:
                      dataDir / &"mainnet-epoch-record-{i.uint64:05}.ssz"
                    except ValueError as e:
                      raiseAssert e.msg
                  let res = io2.writeFile(file, SSZ.encode(accumulator.currentEpoch))
                  if res.isErr():
                    error "Failed writing epoch record to file", file, error = res.error
                  else:
                    notice "Succesfully wrote epoch record to file", file

              if count == EPOCH_SIZE - 1:
                info "Updated an epoch", epoch = i
              count.inc()

              if blockHeader.number == mergeBlockNumber - 1:
                let finishedAccumulator = finishAccumulator(accumulator)
                info "Updated last epoch, finished building HistoricalHashesAccumulatorr",
                  epoch = i
                return ok(finishedAccumulator)
            else:
              warn "Skipping record, not a block header", typ = toHex(header.typ)

        err("Not enough headers provided to finish the HistoricalHashesAccumulator")

      let accumulatorRes = buildAccumulator(dataDir, config.writeEpochRecords)
      if accumulatorRes.isErr():
        fatal "Could not build HistoricalHashesAccumulator",
          error = accumulatorRes.error
        quit QuitFailure
      let accumulator = accumulatorRes.get()

      let res = io2.writeFile(accumulatorFile, SSZ.encode(accumulator))
      if res.isErr():
        error "Failed writing HistoricalHashesAccumulator to file",
          file = accumulatorFile, error = res.error
        quit QuitFailure
      else:
        notice "Succesfully wrote HistoricalHashesAccumulator to file",
          file = accumulatorFile
    of HistoryCmd.printAccumulatorData:
      let file = dataDir / config.accumulatorFileNamePrint

      let res = readAccumulator(file)
      if res.isErr():
        fatal "Failed reading HistoricalHashesAccumulator from file",
          error = res.error, file
        quit QuitFailure

      let
        accumulator = res.get()
        accumulatorRoot = hash_tree_root(accumulator)

      info "HistoricalHashesAccumulator decoded successfully", root = accumulatorRoot

      echo "HistoricalHashesAccumulator:"
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
        quit QuitFailure

      let
        startBlockNumber = config.startBlockNumber
        endBlockNumber = config.endBlockNumber

      if (endBlockNumber < startBlockNumber):
        fatal "Start block number should be smaller than end block number",
          startBlockNumber, endBlockNumber
        quit QuitFailure

      proc exportHeaders(
          file: string, startBlockNumber, endBlockNumber: uint64
      ): Result[void, string] =
        # Downloading headers from JSON RPC endpoint
        info "Requesting headers", startBlockNumber, endBlockNumber
        var headers: seq[headers.Header]
        for j in startBlockNumber .. endBlockNumber:
          debug "Requesting block", number = j
          let header = (waitFor noCancel(client.getHeaderByNumber(j))).valueOr:
            fatal "Failed retrieving block header", blockNumber = j, error
            quit QuitFailure
          headers.add(header)

        let fh = ?openFile(file, {OpenFlags.Write, OpenFlags.Create}).mapErr(toString)
        defer:
          discard closeFile(fh)

        info "Writing headers to file", file
        for header in headers:
          discard ?fh.appendRecord(ExecutionBlockHeaderRecord, rlp.encode(header))

        ok()

      let file =
        try:
          dataDir / &"mainnet-headers-{startBlockNumber:05}-{endBlockNumber:05}.e2s"
        except ValueError as e:
          raiseAssert e.msg

      let res = exportHeaders(file, startBlockNumber, endBlockNumber)
      if res.isErr():
        fatal "Failed exporting headers", error = res.error
        quit QuitFailure
    of HistoryCmd.exportHeadersWithProof:
      let
        startBlockNumber = config.startBlockNumber2
        endBlockNumber = config.endBlockNumber2

      if (endBlockNumber < startBlockNumber):
        fatal "Start block number should be smaller than end block number",
          startBlockNumber, endBlockNumber
        quit QuitFailure

      let file =
        &"mainnet-headersWithProof-{startBlockNumber:05}-{endBlockNumber:05}.json"
      let fh = createAndOpenFile(string config.dataDir, file)

      var contentTable: JsonPortalContentTable
      for blockNumber in startBlockNumber .. endBlockNumber:
        let
          epochIndex = getEpochIndex(blockNumber)
          epochHeadersFile = dataDir / &"mainnet-headers-epoch-{epochIndex:05}.e2s"
          epochRecordFile = dataDir / &"mainnet-epoch-record-{epochIndex:05}.ssz"

        let res = readBlockHeaders(epochHeadersFile)
        if res.isErr():
          error "Could not read headers epoch file", error = res.error
          quit QuitFailure

        let blockHeaders = res.get()

        let epochRecordRes = readEpochRecordCached(epochRecordFile)
        if epochRecordRes.isErr():
          error "Could not read epoch record file", error = epochRecordRes.error
          quit QuitFailure

        let epochRecord = epochRecordRes.get()

        let headerIndex = getHeaderRecordIndex(blockNumber, epochIndex)
        let header = blockHeaders[headerIndex]
        if header.isPreMerge():
          let headerWithProof = buildHeaderWithProof(header, epochRecord)
          if headerWithProof.isErr:
            error "Error building proof", error = headerWithProof.error
            quit QuitFailure

          let
            content = headerWithProof.get()
            contentKey = ContentKey(
              contentType: blockHeader,
              blockHeaderKey: BlockKey(blockHash: header.computeRlpHash()),
            )
            encodedContentKey = history_content.encode(contentKey)
            encodedContent = SSZ.encode(content)

          let portalContent = JsonPortalContent(
            content_key: encodedContentKey.asSeq().to0xHex(),
            content_value: encodedContent.to0xHex(),
          )

          contentTable[$blockNumber] = portalContent
        else:
          # TODO: Deal with writing post merge headers
          error "Not a pre merge header"
          quit QuitFailure

      writePortalContentToJson(fh, contentTable)

      try:
        fh.close()
      except IOError as e:
        fatal "Error occured while closing file", error = e.msg
        quit QuitFailure
    of HistoryCmd.exportEra1:
      cmdExportEra1(config)
    of HistoryCmd.verifyEra1:
      cmdVerifyEra1(config)
  of ExporterCmd.beacon:
    let (cfg, forkDigests, _) = getBeaconData()

    case config.beaconCmd
    of BeaconCmd.exportLCBootstrap:
      waitFor exportLCBootstrapUpdate(
        config.restUrl, string config.dataDir, config.trustedBlockRoot, cfg, forkDigests
      )
    of BeaconCmd.exportLCUpdates:
      waitFor exportLCUpdates(
        config.restUrl,
        string config.dataDir,
        config.startPeriod,
        config.count,
        cfg,
        forkDigests,
      )
    of BeaconCmd.exportLCFinalityUpdate:
      waitFor exportLCFinalityUpdate(
        config.restUrl, string config.dataDir, cfg, forkDigests
      )
    of BeaconCmd.exportLCOptimisticUpdate:
      waitFor exportLCOptimisticUpdate(
        config.restUrl, string config.dataDir, cfg, forkDigests
      )
    of BeaconCmd.exportHistoricalRoots:
      waitFor exportHistoricalRoots(
        config.restUrl, string config.dataDir, cfg, forkDigests
      )
    of BeaconCmd.exportBlockProof:
      exportBlockProof(string config.dataDir, string config.eraDir, config.slotNumber)
    of BeaconCmd.exportHeaderWithProof:
      let client = newRpcClient(config.web3Url1)
      let connectRes = waitFor client.connectRpcClient(config.web3Url1)
      if connectRes.isErr():
        fatal "Failed connecting to JSON-RPC client", error = connectRes.error
        quit QuitFailure

      waitFor exportHeaderWithProof(
        client, string config.dataDir, string config.eraDir1, config.slotNumber1
      )
