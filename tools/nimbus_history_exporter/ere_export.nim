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
  ../../portal/eth_history/ere,
  ../../portal/database/era1_db,
  ../../portal/eth_history/block_proofs/historical_hashes_accumulator,
  ../../portal/eth_history/block_proofs/block_proof_historical_hashes_accumulator,
  ../../portal/eth_history/block_proofs/block_proof_historical_roots,
  ../../portal/eth_history/block_proofs/block_proof_historical_summaries,
  ../../execution_chain/common/[hardforks, chain_config],
  ../../execution_chain/db/core_db,
  ../../execution_chain/db/core_db/persistent,
  ../../execution_chain/db/opts,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  ./nimbus_history_exporter_conf,
  ./beacon_proof_builder

from eth/common/eth_types_rlp import computeRlpHash

from ../../portal/network/network_metadata import loadAccumulator

proc exportEreFileFromEra1(
    era: ere.Era,
    db: Era1DB,
    networkName: string,
    mergeBlockNumber: uint64,
    outputDir: string,
    noProofs = false,
    noReceipts = false,
): Result[void, string] =
  ## Premerge only ere file export from era1 files
  let
    startNumber = era.startNumber()
    endNumber = era.endNumber()

  var header: headers.Header
  ?db.getBlockHeader(endNumber, header)

  let
    filename =
      outputDir /
      ereFileName(networkName, era, header.computeRlpHash(), noProofs, noReceipts)
    e2 = openFile(filename, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
      return err(ioErrorMsg(error))
  defer:
    discard closeFile(e2)

  var group = ?EreGroup.init(e2, startNumber, mergeBlockNumber, noReceipts, noProofs)

  # Step 1: iterate to get all headers from Era1DB to be able to construct the HeaderRecord
  # list, epochRecord and accumulatorRoot, + write the headers to the ere
  var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
  var headerList: seq[headers.Header]
  for blockNumber in startNumber .. endNumber:
    var header: headers.Header
    ?db.getBlockHeader(blockNumber, header)

    let td = ?db.getTotalDifficulty(blockNumber)

    headerRecords.add(
      historical_hashes_accumulator.HeaderRecord(
        blockHash: header.computeRlpHash(), totalDifficulty: td
      )
    )

    headerList.add(header)

    ?group.update(e2, blockNumber, header)

  let accumulatorRoot = getEpochRecordRoot(headerRecords)

  # Step 2: get all block bodies from EL db + write to ere
  for blockNumber in startNumber .. endNumber:
    var body: BlockBody
    ?db.getBlockBody(blockNumber, body)

    ?group.update(e2, blockNumber, body)

  # Step 3 (optional): get all receipts from EL db + write to ere
  if not noReceipts:
    for blockNumber in startNumber .. endNumber:
      var receipts: seq[Receipt]
      ?db.getReceipts(blockNumber, receipts)

      ?group.update(e2, blockNumber, receipts.to(seq[StoredReceipt]))

  # Step 4 (optional): build proofs + write to ere
  if not noProofs:
    let epochRecord = EpochRecord.init(@headerRecords)
    for blockNumber in startNumber .. endNumber:
      let proof = ?buildProof(headerList[blockNumber - startNumber], epochRecord)

      ?group.update(e2, blockNumber, Proof.init(proof))

  # Step 5: total difficulty
  for blockNumber in startNumber .. endNumber:
    let td = ?db.getTotalDifficulty(blockNumber)

    ?group.update(e2, blockNumber, td)

  ?group.finish(e2, Opt.some(accumulatorRoot), era.endNumber())

  notice "Exported ere file", file = filename

  ok()

proc exportEreFile(
    era: ere.Era,
    db: CoreDbTxRef,
    networkName: string,
    mergeBlockNumber: uint64,
    beaconBuilder: Opt[BeaconProofBuilder],
    outputDir: string,
    noProofs = false,
    noReceipts = false,
): Result[void, string] =
  ## ere file export using the nimbus_execution_client database and CL era files.
  ## Handles pre-merge, merge, and post-merge eras:
  ##
  ## Pre-merge era  (era.endNumber() < mergeBlockNumber):
  ##   - HistoricalHashesAccumulatorProof, TD, accumulatorRoot stored.
  ##
  ## Merge era  (startNumber <= mergeBlockNumber <= endNumber):
  ##   - Pre-merge blocks:  HistoricalHashesAccumulatorProof, TD.
  ##   - Post-merge blocks: BlockProofHistoricalRoots, TD frozen at merge TD.
  ##   - accumulatorRoot covers only the pre-merge blocks.
  ##
  ## Post-merge era  (era.startNumber() > mergeBlockNumber):
  ##   - BlockProofHistoricalRoots / HistoricalSummaries / HistoricalSummariesDeneb (fork-dependent),
  ##     no TD.
  let
    startNumber = era.startNumber()
    endNumber = era.endNumber()

    isPreMerge = endNumber < mergeBlockNumber
    isMergeEra = startNumber <= mergeBlockNumber and mergeBlockNumber <= endNumber

    endHeaderHash = (?db.getBlockHeader(endNumber)).computeRlpHash()
    filename =
      outputDir / ereFileName(networkName, era, endHeaderHash, noProofs, noReceipts)

    e2 = openFile(filename, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
      return err(ioErrorMsg(error))

  defer:
    discard closeFile(e2)

  var group = ?EreGroup.init(e2, startNumber, mergeBlockNumber, noReceipts, noProofs)

  # Step 1: get all headers from EL db to be able to construct the HeaderRecord
  # list, epochRecord and accumulatorRoot, and write the headers to the ere file.
  var headerList: seq[headers.Header]
  # headerRecords only gets populated for pre-merge blocks, required for proof + accumulator
  var headerRecords: seq[historical_hashes_accumulator.HeaderRecord]
  for blockNumber in startNumber .. endNumber:
    let header = ?db.getBlockHeader(blockNumber)
    headerList.add(header)
    ?group.update(e2, blockNumber, header)

    if blockNumber < mergeBlockNumber:
      let
        blockHash = header.computeRlpHash()
        td = db.getScore(blockHash).valueOr:
          return err("No total difficulty for block " & $blockNumber)
      headerRecords.add(
        historical_hashes_accumulator.HeaderRecord(
          blockHash: blockHash, totalDifficulty: td
        )
      )

  # Set accumulator root for pre-merge and merge eras only
  # https://github.com/eth-clients/e2store-format-specs/blob/ca2523a6420d64336000f5607c0b59df1a08c83b/formats/ere.md#merge-transition
  let accumulatorRoot =
    if headerRecords.len > 0:
      Opt.some(getEpochRecordRoot(headerRecords))
    else:
      Opt.none(Digest)

  # Step 2: get all block bodies from EL db + write to ere
  for blockNumber in startNumber .. endNumber:
    let body = ?db.getBlockBody(headerList[blockNumber - startNumber])
    ?group.update(e2, blockNumber, body)

  # Step 3 (optional): get all receipts from EL db + write to ere
  if not noReceipts:
    for blockNumber in startNumber .. endNumber:
      let receipts = ?db.getReceipts(headerList[blockNumber - startNumber].receiptsRoot)
      ?group.update(e2, blockNumber, receipts)

  # Step 4 (optional): build proofs + write to ere
  if not noProofs:
    let epochRecord =
      if isPreMerge or isMergeEra:
        EpochRecord.init(@headerRecords)
      else:
        default(EpochRecord) # post-merge era, not used
    for blockNumber in startNumber .. endNumber:
      let header = headerList[blockNumber - startNumber]
      if blockNumber < mergeBlockNumber:
        # Pre-merge: Use `HistoricalHashesAccumulatorProof`, no era files needed
        let proof = ?buildProof(header, epochRecord)
        ?group.update(e2, blockNumber, Proof.init(proof))
      else:
        # Post-merge: beacon chain proof built from era files
        let builder = beaconBuilder.valueOr:
          return err(
            "--era-dir required for post-merge proof building (block " & $blockNumber &
              ")"
          )
        ?group.update(e2, blockNumber, ?builder.buildProof(header.timestamp.uint64))

  # Step 5: total difficulty, only in pre-merge and merge eras
  # https://github.com/eth-clients/e2store-format-specs/blob/ca2523a6420d64336000f5607c0b59df1a08c83b/formats/ere.md#merge-transition
  if isPreMerge or isMergeEra:
    # Total difficulty frozen at the merge block for all post-merge blocks in
    # the merge era.
    let mergeTD =
      if isMergeEra:
        let mergeHeader = ?db.getBlockHeader(mergeBlockNumber)
        db.getScore(mergeHeader.computeRlpHash()).valueOr:
          return err("No total difficulty for merge block " & $mergeBlockNumber)
      else:
        default(UInt256) # pre-merge era, not used
    for blockNumber in startNumber .. endNumber:
      let td =
        if blockNumber < mergeBlockNumber:
          # TD already fetched and cached in headerRecords during step 1
          headerRecords[blockNumber - startNumber].totalDifficulty
        else:
          mergeTD
      ?group.update(e2, blockNumber, td)

  ?group.finish(e2, accumulatorRoot, era.endNumber())

  notice "Exported ere file", file = filename

  ok()

proc exportEre*(config: HistoryExportConf) =
  ## Export ere files from the Nimbus EL database.
  ## Covers pre-merge, merge, and post-merge eras.
  let
    mergeBlockNumber = mergeBlockNumber(config.networkId())
    networkName = config.network
    mergeEra = ere.era(mergeBlockNumber)
    requestedEndEra = ere.Era(config.endEra)
    ereOutputDir = config.ereOutputDir()

  createPath(ereOutputDir).isOkOr:
    fatal "Failed to create ere output directory",
      ereOutputDir, error = ioErrorMsg(error)
    quit(QuitFailure)

  var beaconBuilder = Opt.none(BeaconProofBuilder)
  if not config.noProofs and requestedEndEra >= mergeEra:
    let builder = BeaconProofBuilder.init(config.eraDirPath(), networkName).valueOr:
      fatal "Failed to initialise BeaconProofBuilder", error = error
      quit(QuitFailure)
    beaconBuilder = Opt.some(builder)

  let coreDb = AristoDbRocks.newCoreDbRef(config.elDataDirPath(), DbOptions.init())
  defer:
    coreDb.close()
  let txFrame = coreDb.baseTxFrame()

  for era in ere.Era(config.startEra) .. requestedEndEra:
    exportEreFile(
      era, txFrame, networkName, mergeBlockNumber, beaconBuilder, ereOutputDir,
      config.noProofs, config.noReceipts,
    ).isOkOr:
      fatal "Error exporting ere file",
        era = era,
        msg = error,
        elDir = config.elDataDirPath(),
        hint =
          "Ensure the nimbus execution client is fully synced to cover the requested era range"
      quit(QuitFailure)

proc exportEreFromEra1*(config: HistoryExportConf) =
  ## Export ere files from era1 archive files.
  ## Only covers pre-merge history; eras beyond the merge block are skipped.
  let
    mergeBlockNumber = mergeBlockNumber(config.networkId())
    networkName = config.network
    mergeEra = ere.era(mergeBlockNumber)
    preMergeEndEra = min(ere.Era(config.endEraEra1), mergeEra - 1)
    ereOutputDir = config.ereOutputDir()

  createPath(ereOutputDir).isOkOr:
    fatal "Failed to create ere output directory",
      ereOutputDir, error = ioErrorMsg(error)
    quit(QuitFailure)

  let era1DB =
    Era1DB.new(config.era1DirPath(), networkName, loadAccumulator(networkName), mergeBlockNumber)

  for era in ere.Era(config.startEraEra1) .. preMergeEndEra:
    exportEreFileFromEra1(
      era, era1DB, networkName, mergeBlockNumber, ereOutputDir, config.noProofsEra1,
      config.noReceiptsEra1,
    ).isOkOr:
      fatal "Error exporting ere file", era = era, msg = error
      quit(QuitFailure)

proc verifyEreFile(ereFilename: string, v: HeaderVerifier): Result[void, string] =
  ## Verify a single ere file using a pre-loaded HeaderVerifier.
  let
    (network, noProofs, noReceipts) = ?parseEreFileName(ereFilename)
    nid = parseNetworkId(network).valueOr:
      return err("Unsupported network in filename '" & ereFilename & "': " & error)
    networkMetadata = getMetadataForNetwork(network)
    f = EreFile.open(ereFilename, mergeBlockNumber(nid), noProofs, noReceipts).valueOr:
      return err("Failed to open ere file: " & error)
  defer:
    close(f)

  let
    root = ?f.verify(v, networkMetadata.cfg)
    accumulatorRoot =
      if root.isSome:
        root.value().data.to0xHex()
      else:
        "none"
  notice "ere file succesfully verified",
    accumulatorRoot, noReceipts, noProofs, file = ereFilename
  ok()

proc buildHeaderVerifier(
    config: HistoryExportConf, network: string
): Result[HeaderVerifier, string] =
  let
    networkMetadata = getMetadataForNetwork(network)
    eraDirPath =
      if config.eraDir.isSome:
        config.eraDir.get().string
      else:
        defaultDataDir("", network) / "era"
    (historicalRoots, historicalSummaries) =
      ?loadHistoricalDataFromEraDir(networkMetadata.cfg, eraDirPath)
  ok(
    HeaderVerifier(
      historicalHashes: loadAccumulator(network),
      historicalRoots: historicalRoots,
      historicalSummaries: historicalSummaries,
    )
  )

proc verifyEreFile*(
    config: HistoryExportConf, ereFilename: string
): Result[void, string] =
  let
    (network, _, _) = ?parseEreFileName(ereFilename)
    v = ?buildHeaderVerifier(config, network)
  verifyEreFile(ereFilename, v)

proc verifyEreDir*(config: HistoryExportConf, dirPath: string) =
  var
    v: HeaderVerifier
    verifierReady = false
    count, failed = 0
  try:
    for kind, path in walkDir(dirPath):
      if kind == pcFile and path.splitFile.ext == ".ere":
        inc count
        if not verifierReady:
          let (network, _, _) = parseEreFileName(path).valueOr:
            fatal "Cannot parse ere filename", file = path, error = error
            quit(QuitFailure)
          v = buildHeaderVerifier(config, network).valueOr:
            fatal "Failed to load historical data from era files", error = error
            quit(QuitFailure)
          verifierReady = true
        verifyEreFile(path, v).isOkOr:
          warn "Verification failed", file = path, error = error
          inc failed
  except OSError as e:
    fatal "Failed to read directory", dir = dirPath, error = e.msg
    quit(QuitFailure)

  if failed > 0:
    fatal "Verification completed with failures", total = count, failed
    quit(QuitFailure)
  elif count == 0:
    notice "No ere files found to verify", dir = dirPath
  else:
    notice "All ere files verified successfully", total = count, dir = dirPath
