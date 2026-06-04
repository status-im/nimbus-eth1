# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[os, strformat],
  chronicles,
  stew/[byteutils, io2],
  ssz_serialization,
  ../../portal/eth_history/block_proofs/historical_hashes_accumulator,
  ../../portal/eth_history/history_data_ssz_e2s, # readAccumulator, TODO: Move?
  ../../execution_chain/db/core_db,
  ../../execution_chain/db/core_db/persistent,
  ../../execution_chain/db/opts,
  ./nimbus_history_exporter_conf

proc exportAccumulator*(config: HistoryExportConf) =
  let
    mergeBlock = mergeBlockNumber(config.networkId())
    outputDir = string config.accumulatorOutputDir

  createPath(outputDir).isOkOr:
    fatal "Failed to create accumulator output directory",
      outputDir, error = ioErrorMsg(error)
    quit(QuitFailure)

  let accumulatorFile =
    outputDir / (config.network & "_historical_hashes_accumulator.ssz")
  if isFile(accumulatorFile):
    notice "HistoricalHashesAccumulator file already exists", file = accumulatorFile
    quit(QuitSuccess)

  let coreDb = AristoDbRocks.newCoreDbRef(config.elDataDirPath(), DbOptions.init())
  defer:
    coreDb.close()
  let db = coreDb.baseTxFrame()

  var accumulator = HistoricalHashesAccumulator.init()

  for blockNumber in 0'u64 ..< mergeBlock:
    let header = db.getBlockHeader(blockNumber).valueOr:
      fatal "Failed to get block header",
        blockNumber,
        error = error,
        elDir = config.elDataDirPath(),
        hint =
          "Ensure the nimbus execution client is fully synced to cover the requested block range"
      quit(QuitFailure)

    updateAccumulator(accumulator, header)

    if config.writeEpochRecords:
      if accumulator.currentEpoch.len() == EPOCH_SIZE or blockNumber == mergeBlock - 1:
        let
          epoch = blockNumber div EPOCH_SIZE
          epochFile = outputDir / (config.network & &"-epoch-record-{epoch:05}.ssz")

        io2.writeFile(epochFile, SSZ.encode(accumulator.currentEpoch)).isOkOr:
          error "Failed writing epoch record",
            file = epochFile, error = ioErrorMsg(error)
        notice "Wrote epoch record", file = epochFile

    if blockNumber mod 8192 == 0:
      info "Building accumulator", blockNumber, total = mergeBlock

  let finished = finishAccumulator(accumulator)
  let accumulatorRoot = hash_tree_root(finished)

  io2.writeFile(accumulatorFile, SSZ.encode(finished)).isOkOr:
    fatal "Failed writing HistoricalHashesAccumulator",
      file = accumulatorFile, error = ioErrorMsg(error)
    quit(QuitFailure)

  notice "HistoricalHashesAccumulator written",
    file = accumulatorFile, root = accumulatorRoot.data.to0xHex()

proc printAccumulator*(config: HistoryExportConf) =
  let accumulator = readAccumulator(config.accumulatorFile.string).valueOr:
    fatal "Failed reading HistoricalHashesAccumulator",
      file = config.accumulatorFile.string, error = error
    quit(QuitFailure)

  let root = hash_tree_root(accumulator)

  echo "HistoricalHashesAccumulator:"
  echo "-------------------"
  echo "Root: " & root.data.to0xHex()
  echo ""
  echo "Historical Epochs:"
  echo "------------------"
  echo "Epoch Root"
  for i, epochRoot in accumulator.historicalEpochs:
    echo &"{i.uint64:05} 0x{epochRoot.toHex()}"
