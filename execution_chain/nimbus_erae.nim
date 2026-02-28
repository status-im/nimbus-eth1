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

proc exportEraE*(config: ExecutionClientConf, com: CommonRef) =
  # Data sources:
  # - Pre-merge: era1 or EL db
  # - Merge era: era1 + era + EL db for receipts?
  # - Post-merge: era + EL db for receipts?

  # TODO: Implement merge era and post merge eras

  # TODO: configurable per network
  let cfg = chainConfigForNetwork(MainNet)
  let db = Era1DB.new(config.era1Dir, "mainnet", loadAccumulator(), cfg.posBlock.get())

  for era in EraE(config.startEra) .. EraE(config.endEra):
    # which digest do we use? AccumulatorRoot is only for premerge
    let filename = eraeFileName("mainnet", EraE(era), default(Digest))
    let e2 =
      openFile(filename, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
        fatal "Cannot open file for writing", filename, msg=error
        quit(QuitFailure)
    defer:
      discard closeFile(e2)

    let startNumber = era.startNumber()
    var group = EraEGroup.init(e2, startNumber, cfg.posBlock.value()).get() # use el config

    var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
    # First iterate to get all headers to be able to construct HeaderRecord List and build proofs
    for blockNumber in startNumber..era.endNumber():
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

      group.update(e2, blockNumber, header).isOkOr:
        fatal "Error writing header to erae", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

    let accumulatorRoot = getEpochRecordRoot(headerRecords)
    let epochRecord = EpochRecord.init(@headerRecords)

    # Then iterate again to get bodies and receipts and write everything to file together with the proof
    for blockNumber in startNumber..era.endNumber():
      var blockTuple: BlockTuple
      db.getBlockTuple(blockNumber, blockTuple).isOkOr:
        fatal "Error getting block tuple", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)
      let td = db.getTotalDifficulty(blockNumber).valueOr:
        fatal "Error getting total difficulty", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

      group.update(e2, blockNumber, blockTuple.body).isOkOr:
        fatal "Error writing body to erae", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

      group.update(e2, blockNumber, blockTuple.receipts.to(seq[StoredReceipt])).isOkOr:
        fatal "Error writing receipts to erae", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

      let proof = buildProof(blockTuple.header, epochRecord).valueOr:
        fatal "Error building proof", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

      group.update(e2, blockNumber, proof).isOkOr:
        fatal "Error writing proof to erae", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

      group.update(e2, blockNumber, td).isOkOr:
        fatal "Error writing total difficulty to erae", era=era, blockNumber=blockNumber, msg=error
        quit(QuitFailure)

    group.finish(e2, Opt.some(accumulatorRoot), era.endNumber()).isOkOr:
      fatal "Error finishing erae file", era=era, msg=error
      quit(QuitFailure)

# TODO: Adjust into version that verifies a full area directory
proc verifyEraEFile*(config: ExecutionClientConf, eraeFilename: string) =
  let cfg = chainConfigForNetwork(MainNet)
  let networkData = loadNetworkData("mainnet")
  let f = EraEFile.open(eraeFilename).valueOr:
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

  notice "EraE file succesfully verified",
    accumulatorRoot = root.data.to0xHex(), file = eraeFilename
