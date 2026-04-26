# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  stew/[io2, byteutils],
  ../portal/eth_history/erae,
  ../portal/database/era1_db,
  ../portal/eth_history/block_proofs/historical_hashes_accumulator,
  ../portal/eth_history/block_proofs/block_proof_historical_hashes_accumulator,
  ../portal/network/beacon/beacon_init_loader,
  ./common/[hardforks, chain_config, common],
  ./conf

from ../portal/network/network_metadata import loadAccumulator, loadHistoricalRoots

# Premerge eraE export
proc exportEraEFile(era: EraE, db: Era1DB, networkName: string, mergeBlockNumber: uint64) =
  let startNumber = era.startNumber()

  let endNumber = era.endNumber()
  var header: headers.Header
  db.getBlockHeader(endNumber, header).isOkOr:
    fatal "Error getting block header", era=era, blockNumber=endNumber, msg=error
    quit(QuitFailure)

  # Note: using block hash as shortened hash in filename of erae
  let filename = eraeFileName(networkName, EraE(era), header.computeRlpHash())
  let e2 =
    openFile(filename, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
      fatal "Cannot open file for writing", filename, msg=error
      quit(QuitFailure)
  defer:
    discard closeFile(e2)

  var group = EraEGroup.init(e2, startNumber, mergeBlockNumber).get()

  # First iterate to get all headers to be able to construct HeaderRecord List, epochRecord
  # and accumulatorRoot, and write headers to area file
  var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
  var headerList: seq[headers.Header]
  for blockNumber in startNumber..endNumber:
    var header: headers.Header
    db.getBlockHeader(blockNumber, header).isOkOr:
      fatal "Error getting block header", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

    let td = db.getTotalDifficulty(blockNumber).valueOr:
      fatal "Error getting total difficulty", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

    headerRecords.add(
      historical_hashes_accumulator.HeaderRecord(
        blockHash: header.computeRlpHash(), totalDifficulty: td
      )
    )

    headerList.add(header)

    group.update(e2, blockNumber, header).isOkOr:
      fatal "Error writing header to erae", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

  let accumulatorRoot = getEpochRecordRoot(headerRecords)
  let epochRecord = EpochRecord.init(@headerRecords)

  # Next iterate to get bodies, receipts, proofs and total difficulties
  # and write them to erae file
  for blockNumber in startNumber..endNumber:
    var body: BlockBody
    db.getBlockBody(blockNumber, body).isOkOr:
      fatal "Error getting block body", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

    group.update(e2, blockNumber, body).isOkOr:
      fatal "Error writing body to erae", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

  for blockNumber in startNumber..endNumber:
    var receipts: seq[Receipt]
    db.getReceipts(blockNumber, receipts).isOkOr:
      fatal "Error getting receipts", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

    group.update(e2, blockNumber, receipts.to(seq[StoredReceipt])).isOkOr:
      fatal "Error writing receipts to erae", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

  for blockNumber in startNumber..endNumber:
    let proof = buildProof(headerList[blockNumber - startNumber], epochRecord).valueOr:
      fatal "Error building proof", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

    group.update(e2, blockNumber, proof).isOkOr:
      fatal "Error writing proof to erae", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

  for blockNumber in startNumber..endNumber:
    let td = db.getTotalDifficulty(blockNumber).valueOr:
      fatal "Error getting total difficulty", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

    group.update(e2, blockNumber, td).isOkOr:
      fatal "Error writing total difficulty to erae", era=era, blockNumber=blockNumber, msg=error
      quit(QuitFailure)

  group.finish(e2, Opt.some(accumulatorRoot), era.endNumber()).isOkOr:
    fatal "Error finishing erae file", era=era, msg=error
    quit(QuitFailure)

proc exportEraE*(config: ExecutionClientConf, com: CommonRef) =
  # Data sources:
  # - Pre-merge: era1 or EL db
  # - Merge era: era1 + era + EL db for receipts?
  # - Post-merge: era + EL db for receipts?

  let
    cfg = chainConfigForNetwork(config.networkId)
    mergeBlockNumber =
      if cfg.posBlock.isSome:
        cfg.posBlock.value()
      elif cfg.mergeNetsplitBlock.isSome:
        cfg.mergeNetsplitBlock.value()
      else:
        BlockNumber(0)
    networkName =
      if config.networkId == MainNet:
        "mainnet"
      elif config.networkId == SepoliaNet:
        "sepolia"
      else:
        raiseAssert "Other networks are unsupported or do not have an era1"
    # TODO: Need to make loadAccumulator and loadHistoricalRoots configurable to load
    # per network.
    era1DB = Era1DB.new(config.era1Dir, networkName, loadAccumulator(), mergeBlockNumber)

    networkData = loadNetworkData(networkName)
    # eraDB = EraDB.new(networkData.metadata.cfg, conf.eraDir, networkData.genesis_validators_root)

    mergeEra = erae.era(mergeBlockNumber)
    preMergeEndEra = min(EraE(config.endEra), EraE(mergeEra - 1))

  for era in EraE(config.startEra) .. preMergeEndEra:
    exportEraEFile(era, era1DB, networkName, mergeBlockNumber)

# TODO: Adjust into version that verifies a full erae directory
proc verifyEraEFile*(config: ExecutionClientConf, eraeFilename: string) =
  let cfg = chainConfigForNetwork(config.networkId)
  let mergeBlockNumber =
    if cfg.posBlock.isSome:
      cfg.posBlock.value()
    elif cfg.mergeNetsplitBlock.isSome:
      cfg.mergeNetsplitBlock.value()
    else:
      BlockNumber(0)
  let networkData = loadNetworkData("mainnet")
  let f = EraEFile.open(eraeFilename, mergeBlockNumber, config.hasProofs).valueOr:
    warn "Failed to open era file", error = error
    quit QuitFailure
  defer:
    close(f)

  let v = HeaderVerifier(
    historicalHashes: loadAccumulator(),
    historicalRoots: loadHistoricalRoots(),
    # TODO: historicalSummaries from state in latest era file
  )
  let root = f.verify(v, networkData.metadata.cfg).valueOr:
    warn "Verification of era file failed", error = error
    quit QuitFailure

  let accumulatorRoot = if root.isSome: root.value().data.to0xHex() else: "none"
  notice "EraE file succesfully verified",
    accumulatorRoot, file = eraeFilename
