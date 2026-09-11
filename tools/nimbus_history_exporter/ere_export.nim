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
  std/[algorithm, os],
  chronicles,
  stew/[io2, byteutils],
  ../../execution_chain/history/e2store_formats/ere,
  ../../execution_chain/history/db/era1_db,
  ../../execution_chain/history/block_proofs/historical_hashes_accumulator,
  ../../execution_chain/history/block_proofs/block_proof_historical_hashes_accumulator,
  ../../execution_chain/history/block_proofs/block_proof_historical_roots,
  ../../execution_chain/history/block_proofs/block_proof_historical_summaries,
  ../../execution_chain/common/[hardforks, chain_config, genesis],
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

  let filename =
    outputDir /
    ereFileName(networkName, era, header.computeRlpHash(), noProofs, noReceipts)

  if isFile(filename):
    debug "Ere file already exists", era, file = filename
    return ok()

  let
    tmpName = filename & ".tmp"
    e2 = openFile(tmpName, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
      return err(ioErrorMsg(error))

  var completed = false
  defer:
    if not completed:
      discard io2.removeFile(tmpName)

  block writeBlock:
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

  # std/os.moveFile raises Exception (not raises-annotated), so we must catch
  # Exception here. Practically it will only ever raise OSError.
  try:
    moveFile(tmpName, filename)
  except Exception as e:
    return err("Failed to rename ere tmp file: " & e.msg)
  completed = true

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

  if isFile(filename):
    debug "Ere file already exists", era, file = filename
    return ok()

  let
    tmpName = filename & ".tmp"
    e2 = openFile(tmpName, {OpenFlags.Write, OpenFlags.Create, OpenFlags.Truncate}).valueOr:
      return err(ioErrorMsg(error))

  var completed = false
  defer:
    if not completed:
      discard io2.removeFile(tmpName)

  block writeBlock:
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
        let receipts =
          ?db.getReceipts(headerList[blockNumber - startNumber].receiptsRoot)
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
          # The block hash is only needed from Gloas onwards, where the proof is
          # built from the beacon block that confirms this execution block
          let proof = ?builder.buildProof(
            header.timestamp.uint64, Digest(data: header.computeRlpHash().data)
          )
          ?group.update(e2, blockNumber, proof)

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

  # std/os.moveFile raises Exception (not raises-annotated), so we must catch
  # Exception here. Practically it will only ever raise OSError.
  try:
    moveFile(tmpName, filename)
  except Exception as e:
    return err("Failed to rename ere tmp file: " & e.msg)
  completed = true

  notice "Exported ere file", file = filename

  ok()

proc exportEre*(config: HistoryExportConf) =
  ## Export ere files from the Nimbus EL database.
  ## Covers pre-merge, merge, and post-merge eras.
  let
    mergeBlockNumber = mergeBlockNumber(config.networkId())
    networkName = config.network
    mergeEra = ere.era(mergeBlockNumber)
    startEra = ere.Era(config.era)
    endEra =
      if config.eraCount == 0:
        ere.Era(high(uint64))
      else:
        ere.Era(config.era + config.eraCount - 1)
    ereOutputDir = config.ereOutputDir()

  createPath(ereOutputDir).isOkOr:
    fatal "Failed to create ere output directory",
      ereOutputDir, error = ioErrorMsg(error)
    quit(QuitFailure)

  var beaconBuilder = Opt.none(BeaconProofBuilder)
  if not config.noProofs and endEra >= mergeEra:
    let builder = BeaconProofBuilder.init(config.eraDirPath(), networkName).valueOr:
      fatal "Failed to initialise BeaconProofBuilder", error = error
      quit(QuitFailure)
    beaconBuilder = Opt.some(builder)

  let coreDb = AristoDbRocks.newCoreDbRef(config.elDataDirPath(), DbOptions.init())
  defer:
    coreDb.close()
  let txFrame = coreDb.baseTxFrame()
  let highestBlock = txFrame.stateBlockNumber()

  for era in startEra .. endEra:
    if era.endNumber() > highestBlock:
      notice "Written all complete eras", era, highestBlock
      break

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

  if mergeBlockNumber == 0:
    fatal "exportEreFromEra1 is not supported for PoS only networks",
      network = networkName
    quit(QuitFailure)

  let
    mergeEra = ere.era(mergeBlockNumber)
    startEraFromEra1 = ere.Era(config.eraEra1)
    endEraFromEra1 =
      if config.eraCountEra1 == 0:
        mergeEra - 1
      else:
        min(ere.Era(config.eraEra1 + config.eraCountEra1 - 1), mergeEra - 1)
    ereOutputDir = config.ereOutputDir()

  createPath(ereOutputDir).isOkOr:
    fatal "Failed to create ere output directory",
      ereOutputDir, error = ioErrorMsg(error)
    quit(QuitFailure)

  let era1DB = Era1DB.new(
    config.era1DirPath(), networkName, loadAccumulator(networkName), mergeBlockNumber
  )
  defer:
    era1DB.dispose()

  for era in startEraFromEra1 .. endEraFromEra1:
    exportEreFileFromEra1(
      era, era1DB, networkName, mergeBlockNumber, ereOutputDir, config.noProofsEra1,
      config.noReceiptsEra1,
    ).isOkOr:
      fatal "Error exporting ere file", era = era, msg = error
      quit(QuitFailure)

proc verifyEreFile(ereFilename: string, v: HeaderVerifier): Result[void, string] =
  ## Verify a single ere file using a pre-loaded HeaderVerifier.
  let
    (network, _, noProofs, noReceipts) = ?parseEreFileName(ereFilename)
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
    nid = parseNetworkId(network).valueOr:
      return err("Unsupported network '" & network & "': " & error)
    networkMetadata = getMetadataForNetwork(network)
    eraDirPath =
      if config.eraDir.isSome:
        config.eraDir.get().string
      else:
        defaultDataDir("", network) / "era"
    (historicalRoots, historicalSummaries) =
      ?loadHistoricalDataFromEraDir(networkMetadata.cfg, eraDirPath)
    isPosOnly = mergeBlockNumber(nid) == 0
    # PoS only networks (e.g. hoodi) have no pre-merge history, so there is no
    # baked-in accumulator to load.
    historicalHashes =
      if isPosOnly:
        Opt.none(FinishedHistoricalHashesAccumulator)
      else:
        Opt.some(loadAccumulator(network))
    # Their genesis block cannot be proven, so it gets verified against the
    # genesis block of the network itself.
    genesisHash =
      if isPosOnly:
        Opt.some(genesisBlockHash(networkParams(nid)))
      else:
        Opt.none(Hash32)
  ok(
    HeaderVerifier(
      historicalHashes: historicalHashes,
      historicalRoots: historicalRoots,
      historicalSummaries: historicalSummaries,
      genesisBlockHash: genesisHash,
    )
  )

proc verifyEreFile*(
    config: HistoryExportConf, ereFilename: string
): Result[void, string] =
  let
    (network, _, _, _) = ?parseEreFileName(ereFilename)
    v = ?buildHeaderVerifier(config, network)
  verifyEreFile(ereFilename, v)

proc verifyEreDir*(config: HistoryExportConf, dirPath: string) =
  var
    files: seq[tuple[era: ere.Era, path: string]]
    firstNetwork: string
  try:
    for kind, path in walkDir(dirPath):
      if kind in {pcFile, pcLinkToFile} and path.splitFile.ext == ".ere":
        let (network, era, _, _) = parseEreFileName(path).valueOr:
          fatal "Cannot parse ere filename", file = path, error = error
          quit(QuitFailure)

        if firstNetwork.len() == 0:
          firstNetwork = network
        elif network != firstNetwork:
          fatal "Directory holds ere files of multiple networks",
            dir = dirPath, network = firstNetwork, otherNetwork = network, file = path
          quit(QuitFailure)

        files.add((era, path))
  except OSError as e:
    fatal "Failed to read directory", dir = dirPath, error = e.msg
    quit(QuitFailure)

  if files.len() == 0:
    notice "No ere files found to verify", dir = dirPath
    return

  # Verify in era order, so that the files are covered chronologically and the
  # era range can be checked for gaps along the way.
  files.sort()

  let v = buildHeaderVerifier(config, firstNetwork).valueOr:
    fatal "Failed to load historical data from era files", error = error
    quit(QuitFailure)

  var failed, missing, duplicateEras = 0
  for i, (era, path) in files:
    if i > 0:
      let previousEra = files[i - 1].era
      if era == previousEra:
        warn "Multiple ere files for the same era", era, file = path
        inc duplicateEras
      elif era > previousEra + 1:
        warn "Missing ere files", firstMissing = previousEra + 1, lastMissing = era - 1
        missing += int(era - previousEra - 1)

    verifyEreFile(path, v).isOkOr:
      warn "Verification failed", file = path, error = error
      inc failed

  if failed > 0 or missing > 0 or duplicateEras > 0:
    fatal "Verification completed with failures",
      total = files.len(), failed, missing, duplicateEras
    quit(QuitFailure)
  else:
    notice "All ere files verified successfully",
      total = files.len(),
      firstEra = files[0].era,
      lastEra = files[^1].era,
      dir = dirPath
