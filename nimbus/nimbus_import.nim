# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  metrics,
  chronos/timer,
  std/[strformat, strutils],
  stew/io2,
  beacon_chain/era_db,
  beacon_chain/networking/network_metadata,
  ./config,
  ./common/common,
  ./core/[block_import, chain],
  ./db/era1_db,
  ./utils/era_helpers

declareGauge nec_import_block_number, "Latest imported block number"

declareCounter nec_imported_blocks, "Blocks processed during import"

declareCounter nec_imported_transactions, "Transactions processed during import"

declareCounter nec_imported_gas, "Gas processed during import"

var running {.volatile.} = true

proc importBlocks*(conf: NimbusConf, com: CommonRef) =
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    running = false

  setControlCHook(controlCHandler)

  let
    start = com.db.getSavedStateBlockNumber() + 1
    chain = com.newChain()

  template boolFlag(flags, b): PersistBlockFlags =
    if b:
      flags
    else:
      {}

  var
    imported = 0'u64
    importedSlot = 1'u64
    gas = GasInt(0)
    txs = 0
    time0 = Moment.now()
    csv =
      if conf.csvStats.isSome:
        try:
          let f = open(conf.csvStats.get(), fmAppend)
          let pos = f.getFileSize()
          if pos == 0:
            f.writeLine("block_number,blocks,slot,txs,gas,time")
          f
        except IOError as exc:
          error "Could not open statistics output file",
            file = conf.csvStats, err = exc.msg
          quit(QuitFailure)
      else:
        File(nil)
    flags =
      boolFlag({PersistBlockFlag.NoValidation}, conf.noValidation) +
      boolFlag({PersistBlockFlag.NoFullValidation}, not conf.fullValidation) +
      boolFlag(NoPersistBodies, not conf.storeBodies) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts) +
      boolFlag({PersistBlockFlag.NoPersistSlotHashes}, not conf.storeSlotHashes)
    blocks: seq[EthBlock]
    clConfig: Eth2NetworkMetadata
    genesis_validators_root: Eth2Digest
    lastEra1Block: uint64
    firstSlotAfterMerge: uint64

  defer:
    if csv != nil:
      close(csv)

  # Network Specific Configurations
  # TODO: the merge block number could be fetched from the era1 file instead,
  #       specially if the accumulator is added to the chain metadata
  if conf.networkId == MainNet:
    doAssert isDir(conf.era1Dir.string), "Era1 directory not found"
    clConfig = getMetadataForNetwork("mainnet")
    genesis_validators_root = Eth2Digest.fromHex(
      "0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95"
    ) # Mainnet Validators Root
    lastEra1Block = 15537393'u64 # Mainnet
    firstSlotAfterMerge =
      if isDir(conf.eraDir.string):
        4700013'u64 # Mainnet
      else:
        warn "No eraDir found for Mainnet, block loading will stop after era1"
        0'u64 # No eraDir for Mainnet
  elif conf.networkId == SepoliaNet:
    doAssert isDir(conf.era1Dir.string), "Era1 directory not found"
    clConfig = getMetadataForNetwork("sepolia")
    genesis_validators_root = Eth2Digest.fromHex(
      "0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078"
    ) # Sepolia Validators Root
    lastEra1Block = 1450408'u64 # Sepolia
    firstSlotAfterMerge =
      if isDir(conf.eraDir.string):
        115193'u64 # Sepolia
      else:
        warn "No eraDir found for Sepolia, block loading will stop after era1"
        0'u64 # No eraDir for Sepolia
  elif conf.networkId == HoleskyNet:
    doAssert isDir(conf.eraDir.string), "Era directory not found"
    clConfig = getMetadataForNetwork("holesky")
    genesis_validators_root = Eth2Digest.fromHex(
      "0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1"
    ) # Holesky Validators Root
    lastEra1Block = 0'u64
    firstSlotAfterMerge = 0'u64
  else:
    error "Unsupported network", network = conf.networkId
    quit(QuitFailure)

  nec_import_block_number.set(start.int64)

  template blockNumber(): uint64 =
    start + imported

  func f(value: float): string =
    &"{value:4.3f}"

  proc process() =
    let
      time1 = Moment.now()
      statsRes = chain.persistBlocks(blocks, flags)
    if statsRes.isErr():
      error "Failed to persist blocks", error = statsRes.error
      quit(QuitFailure)

    txs += statsRes[].txs
    gas += statsRes[].gas
    let
      time2 = Moment.now()
      diff1 = (time2 - time1).nanoseconds().float / 1000000000
      diff0 = (time2 - time0).nanoseconds().float / 1000000000

    info "Imported blocks",
      blockNumber,
      blocks = imported,
      importedSlot,
      txs,
      mgas = f(gas.float / 1000000),
      bps = f(blocks.len.float / diff1),
      tps = f(statsRes[].txs.float / diff1),
      mgps = f(statsRes[].gas.float / 1000000 / diff1),
      avgBps = f(imported.float / diff0),
      avgTps = f(txs.float / diff0),
      avgMGps = f(gas.float / 1000000 / diff0),
      elapsed = toString(time2 - time0, 3)

    metrics.set(nec_import_block_number, int64(blockNumber))
    nec_imported_blocks.inc(blocks.len)
    nec_imported_transactions.inc(statsRes[].txs)
    nec_imported_gas.inc(int64 statsRes[].gas)

    if csv != nil:
      # In the CSV, we store a line for every chunk of blocks processed so
      # that the file can meaningfully be appended to when restarting the
      # process - this way, each sample is independent
      try:
        csv.writeLine(
          [
            $blockNumber,
            $blocks.len,
            $importedSlot,
            $statsRes[].txs,
            $statsRes[].gas,
            $(time2 - time1).nanoseconds(),
          ].join(",")
        )
        csv.flushFile()
      except IOError as exc:
        warn "Could not write csv", err = exc.msg
    blocks.setLen(0)

  # Finds the slot number to resume the import process
  # First it sets the initial lower bound to `firstSlotAfterMerge` + number of blocks after Era1
  # Then it iterates over the slots to find the current slot number, along with reducing the
  # search space by calculating the difference between the `blockNumber` and the `block_number` from the executionPayload
  # of the slot, then adding the difference to the importedSlot. This pushes the lower bound more,
  # making the search way smaller
  proc updateLastImportedSlot(
      era: EraDB,
      historical_roots: openArray[Eth2Digest],
      historical_summaries: openArray[HistoricalSummary],
      endSlot: Slot,
  ): bool =
    # Checks if the Nimbus block number is ahead the era block number
    # First we load the last era number, and get the fist slot number
    # Since the slot emptiness cannot be predicted, we iterate over to find the block and check
    # if the block number is greater than the current block number
    var
      lastEra = era(endSlot - 1)
      startSlot = start_slot(lastEra) - 8192
    debug "Finding slot number to resume import", startSlot, endSlot

    while startSlot < endSlot:
      let blk = getEthBlockFromEra(
        era, historical_roots, historical_summaries, startSlot, clConfig.cfg
      ).valueOr:
        startSlot += 1
        if startSlot == endSlot - 1:
          error "No blocks found in the last era file"
          return false
        else:
          continue

      startSlot += 1
      if blk.header.number < blockNumber:
        notice "Available Era Files are already imported",
          stateBlockNumber = blockNumber, eraBlockNumber = blk.header.number
        quit QuitSuccess
      else:
        break

    if blockNumber > 1:
      # Setting the initial lower bound
      importedSlot = (blockNumber - lastEra1Block) + firstSlotAfterMerge
      debug "Finding slot number after resuming import", importedSlot

      # BlockNumber based slot finding
      var clNum = 0'u64

      while clNum < blockNumber:
        let blk = getEthBlockFromEra(
          era, historical_roots, historical_summaries, Slot(importedSlot), clConfig.cfg
        ).valueOr:
          importedSlot += 1
          continue

        clNum = blk.header.number
        # decreasing the lower bound with each iteration
        importedSlot += blockNumber - clNum

      notice "Resuming import from", importedSlot
    return true

  if isDir(conf.era1Dir.string) or isDir(conf.eraDir.string):
    if start <= lastEra1Block:
      notice "Importing era1 archive",
        start, dataDir = conf.dataDir.string, era1Dir = conf.era1Dir.string

      let db =
        if conf.networkId == MainNet:
          Era1DbRef.init(conf.era1Dir.string, "mainnet").expect("Era files present")
            # Mainnet
        else:
          Era1DbRef.init(conf.era1Dir.string, "sepolia").expect("Era files present")
            # Sepolia
      defer:
        db.dispose()

      proc loadEraBlock(blockNumber: uint64): bool =
        # Separate proc to reduce stack usage of blk
        let blk = db.getEthBlock(blockNumber).valueOr:
          error "Could not load block from era1", blockNumber, error
          return false

        blocks.add blk
        true

      while running and imported < conf.maxBlocks and blockNumber <= lastEra1Block:
        if not loadEraBlock(blockNumber):
          break

        imported += 1

        if blocks.lenu64 mod conf.chunkSize == 0:
          process()

      if blocks.len > 0:
        process() # last chunk, if any

    if blockNumber > lastEra1Block:
      notice "Importing era archive",
        start, dataDir = conf.dataDir.string, eraDir = conf.eraDir.string

      let
        eraDB = EraDB.new(clConfig.cfg, conf.eraDir.string, genesis_validators_root)
        (historical_roots, historical_summaries, endSlot) = loadHistoricalRootsFromEra(
          conf.eraDir.string, clConfig.cfg
        ).valueOr:
          error "Error loading historical summaries", error
          quit QuitFailure

      # Load the last slot number
      var moreEraAvailable = true
      if blockNumber > lastEra1Block + 1:
        moreEraAvailable = updateLastImportedSlot(
          eraDB, historical_roots.asSeq(), historical_summaries.asSeq(), endSlot
        )

      if importedSlot < firstSlotAfterMerge and firstSlotAfterMerge != 0:
        # if resuming import we do not update the slot
        importedSlot = firstSlotAfterMerge

      proc loadEra1Block(importedSlot: Slot): bool =
        # Separate proc to reduce stack usage of blk
        var blk = getEthBlockFromEra(
          eraDB,
          historical_roots.asSeq(),
          historical_summaries.asSeq(),
          importedSlot,
          clConfig.cfg,
        ).valueOr:
          return false

        blocks.add blk
        true

      while running and moreEraAvailable and imported < conf.maxBlocks and
          importedSlot < endSlot:
        if not loadEra1Block(Slot(importedSlot)):
          importedSlot += 1
          continue

        imported += 1
        importedSlot += 1

        if blocks.lenu64 mod conf.chunkSize == 0:
          process()

      if blocks.len > 0:
        process()

  importRlpBlocks(conf, com)
