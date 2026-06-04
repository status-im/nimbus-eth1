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
  std/os,
  chronicles,
  stew/[io2, byteutils],
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  ../../portal/eth_history/era1,
  ../../portal/eth_history/block_proofs/historical_hashes_accumulator,
  ../../execution_chain/db/core_db,
  ../../execution_chain/db/core_db/persistent,
  ../../execution_chain/db/opts,
  ./nimbus_history_exporter_conf

from eth/common/eth_types_rlp import computeRlpHash

proc exportEra1File(
    era: Era1,
    db: CoreDbTxRef,
    networkName: string,
    mergeBlockNumber: uint64,
    outputDir: string,
): Result[void, string] =
  let
    startNumber = era.startNumber()
    endNumber = era1.endNumber(era, mergeBlockNumber)
    tmpName = outputDir / era1FileName(networkName, era, default(Digest)) & ".tmp"

  var accumulatorRoot: Digest
  block writeBlock:
    let e2 = openFile(tmpName, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
      return err(ioErrorMsg(error))
    defer:
      discard closeFile(e2)

    var group = ?Era1Group.init(e2, startNumber, mergeBlockNumber)

    var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
    for blockNumber in startNumber .. endNumber:
      let
        header = ?db.getBlockHeader(blockNumber)
        body = ?db.getBlockBody(header)
        storedReceipts = ?db.getReceipts(header.receiptsRoot)
        receipts = storedReceipts.to(seq[Receipt])
        blockHash = header.computeRlpHash()
        td = db.getScore(blockHash).valueOr:
          return err("No total difficulty for block " & $blockNumber)

      headerRecords.add(
        historical_hashes_accumulator.HeaderRecord(
          blockHash: blockHash, totalDifficulty: td
        )
      )

      ?group.update(e2, blockNumber, header, body, receipts, td)

    accumulatorRoot = getEpochRecordRoot(headerRecords)
    ?group.finish(e2, accumulatorRoot, endNumber)

  let finalName = outputDir / era1FileName(networkName, era, accumulatorRoot)
  if isFile(finalName):
    notice "Era1 file already exists", era = era.uint64, file = finalName
    discard io2.removeFile(tmpName)
    return ok()

  # std/os.moveFile raises Exception (not raises-annotated), so we must catch
  # Exception here. Practically it will only ever raise OSError.
  try:
    moveFile(tmpName, finalName)
  except Exception as e:
    return err("Failed to rename era1 tmp file: " & e.msg)

  notice "Exported era1 file", file = finalName
  ok()

proc exportEra1*(config: HistoryExportConf) =
  let
    mergeBlockNumber = mergeBlockNumber(config.networkId())
    networkName = config.network
    mergeEra = era1.era(mergeBlockNumber)
    startEra1 = Era1(config.eraEra1Export)
    endEra1 =
      if config.eraCountEra1Export == 0:
        mergeEra
      else:
        min(Era1(config.eraEra1Export + config.eraCountEra1Export - 1), mergeEra)
    outputDir = config.era1OutputDirPath()

  createPath(outputDir).isOkOr:
    fatal "Failed to create era1 output directory", outputDir, error = ioErrorMsg(error)
    quit(QuitFailure)

  let coreDb = AristoDbRocks.newCoreDbRef(config.elDataDirPath(), DbOptions.init())
  defer:
    coreDb.close()
  let db = coreDb.baseTxFrame()

  for era in startEra1 .. endEra1:
    exportEra1File(era, db, networkName, mergeBlockNumber, outputDir).isOkOr:
      fatal "Error exporting era1 file",
        era = era.uint64,
        msg = error,
        elDir = config.elDataDirPath(),
        hint =
          "Ensure the nimbus execution client is fully synced to cover the requested era range"
      quit(QuitFailure)

proc verifyEra1*(config: HistoryExportConf) =
  let mergeBlockNumber = mergeBlockNumber(config.networkId())

  var count = 0
  var failed = 0
  try:
    for kind, path in walkDir(config.era1VerifyDir.string):
      if kind == pcFile and path.splitFile.ext == ".era1":
        inc count
        let f = Era1File.open(path, mergeBlockNumber).valueOr:
          warn "Failed to open era1 file", file = path, error = error
          inc failed
          continue
        defer:
          close(f)

        let root = f.verify().valueOr:
          warn "Verification failed", file = path, error = error
          inc failed
          continue

        notice "Era1 file verified", accumulatorRoot = root.data.to0xHex(), file = path
  except OSError as e:
    fatal "Failed to read directory", dir = config.era1VerifyDir.string, error = e.msg
    quit(QuitFailure)

  if failed > 0:
    fatal "Verification completed with failures", total = count, failed
    quit(QuitFailure)
  else:
    notice "All era1 files verified successfully",
      total = count, dir = config.era1VerifyDir.string
