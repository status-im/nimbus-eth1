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
  ../portal/eth_history/ere,
  ../portal/database/era1_db,
  ../portal/eth_history/block_proofs/historical_hashes_accumulator,
  ../portal/eth_history/block_proofs/block_proof_historical_hashes_accumulator,
  ../portal/network/beacon/beacon_init_loader,
  ./common/[hardforks, chain_config, common],
  ./conf

from ../portal/network/network_metadata import loadAccumulator, loadHistoricalRoots

# Premerge ere file export
proc exportEreFile(
    era: Era,
    db: Era1DB,
    networkName: string,
    mergeBlockNumber: uint64,
    noProofs = false,
    noReceipts = false,
): Result[void, string] =
  let
    startNumber = era.startNumber()
    endNumber = era.endNumber()

  var header: headers.Header
  ? db.getBlockHeader(endNumber, header)

  let
    filename = ereFileName(networkName, era, header.computeRlpHash(), noProofs, noReceipts)
    e2 =
      openFile(filename, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
        return err(ioErrorMsg(error))
  defer:
    discard closeFile(e2)

  var group = ? EreGroup.init(e2, startNumber, mergeBlockNumber, noReceipts, noProofs)

  # First iterate to get all headers from Era1DB to be able to construct the HeaderRecord
  # list, epochRecord and accumulatorRoot, and write the headers to the ere file.
  var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
  var headerList: seq[headers.Header]
  for blockNumber in startNumber..endNumber:
    var header: headers.Header
    ? db.getBlockHeader(blockNumber, header)

    let td = ? db.getTotalDifficulty(blockNumber)

    headerRecords.add(
      historical_hashes_accumulator.HeaderRecord(
        blockHash: header.computeRlpHash(), totalDifficulty: td
      )
    )

    headerList.add(header)

    ? group.update(e2, blockNumber, header)

  let accumulatorRoot = getEpochRecordRoot(headerRecords)
  let epochRecord = EpochRecord.init(@headerRecords)

  # Next iterate to get bodies, receipts, proofs and total difficulties
  # and write them to the ere file.
  for blockNumber in startNumber..endNumber:
    var body: BlockBody
    ? db.getBlockBody(blockNumber, body)

    ? group.update(e2, blockNumber, body)

  if not noReceipts:
    for blockNumber in startNumber..endNumber:
      var receipts: seq[Receipt]
      ? db.getReceipts(blockNumber, receipts)

      ? group.update(e2, blockNumber, receipts.to(seq[StoredReceipt]))

  if not noProofs:
    for blockNumber in startNumber..endNumber:
      let proof = ? buildProof(headerList[blockNumber - startNumber], epochRecord)

      ? group.update(e2, blockNumber, proof)

  for blockNumber in startNumber..endNumber:
    let td = ? db.getTotalDifficulty(blockNumber)

    ? group.update(e2, blockNumber, td)

  ? group.finish(e2, Opt.some(accumulatorRoot), era.endNumber())

  notice "Exported ere file", file = filename

  ok()

proc exportEre*(config: ExecutionClientConf, com: CommonRef) =
  # Data sources:
  # - Pre-merge: era1 or EL db
  # - Merge era: era + era and/or EL db for receipts
  # - Post-merge: era + EL db for receipts

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

    mergeEra = ere.era(mergeBlockNumber)
    preMergeEndEra = min(Era(config.endEra), mergeEra - 1)

  for era in Era(config.startEra) .. preMergeEndEra:
    exportEreFile(era, era1DB, networkName, mergeBlockNumber, config.noProofs, config.noReceipts).isOkOr:
      fatal "Error exporting ere file", era = era, msg = error
      quit(QuitFailure)

# TODO: Adjust into version that verifies a full ere directory instead of a single file
proc verifyEreFile*(config: ExecutionClientConf, ereFilename: string) =
  let cfg = chainConfigForNetwork(config.networkId)
  let mergeBlockNumber =
    if cfg.posBlock.isSome:
      cfg.posBlock.value()
    elif cfg.mergeNetsplitBlock.isSome:
      cfg.mergeNetsplitBlock.value()
    else:
      BlockNumber(0)
  let networkData = loadNetworkData("mainnet")
  let (noProofs, noReceipts) = parseEreFileProfile(ereFilename)
  let f = EreFile.open(ereFilename, mergeBlockNumber, noProofs, noReceipts).valueOr:
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
    warn "Verification of ere file failed", error = error
    quit QuitFailure

  let accumulatorRoot = if root.isSome: root.value().data.to0xHex() else: "none"
  notice "ere file succesfully verified",
    accumulatorRoot,
    noReceipts,
    noProofs,
    file = ereFilename
