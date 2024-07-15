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
  std/[os, strformat, strutils],
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

func shortLog(a: timer.Duration, parts = int.high): string {.inline.} =
  ## Returns string representation of Duration ``a`` as nanoseconds value.
  var
    res = ""
    v = a.nanoseconds()
    parts = parts

  template f(n: string, T: Duration) =
    if v >= T.nanoseconds():
      res.add($(uint64(v div T.nanoseconds())))
      res.add(n)
      v = v mod T.nanoseconds()
      dec parts
      if v == 0 or parts <= 0:
        return res

  f("w", Week)
  f("d", Day)
  f("h", Hour)
  f("m", Minute)
  f("s", Second)
  f("ms", Millisecond)
  f("us", Microsecond)
  f("ns", Nanosecond)

  res

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
      boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts)
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
        notice "No eraDir found for Mainnet, block loading will stop after era1"
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
        notice "No eraDir found for Sepolia, block loading will stop after era1"
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
    try:
      &"{value:4.3f}"
    except ValueError:
      raiseAssert "valid fmt string"

  template process() =
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
      elapsed = shortLog(time2 - time0, 3)

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

  template updateLastImportedSlot(
      era: EraDB,
      historical_roots: openArray[Eth2Digest],
      historical_summaries: openArray[HistoricalSummary],
  ) =
    if blockNumber > 1:
      importedSlot = ( blockNumber - lastEra1Block ) + firstSlotAfterMerge
      notice "Finding slot number after resuming import", importedSlot
      var parentHash: common.Hash256
      var checkOnce = true
      let currentHash = com.db.getHeadBlockHash()
      while currentHash != parentHash:
        let clBlock = getBlockFromEra(
          era, historical_roots, historical_summaries, Slot(importedSlot), clConfig.cfg
        )
        if clBlock.isSome:
          let ethBlock = getEth1Block(clBlock.get())
          parentHash = ethBlock.header.parentHash
          if checkOnce:
            importedSlot += blockNumber - ethBlock.header.number - 1
            checkOnce = false
            continue
          
        importedSlot += 1
      importedSlot -= 1
      notice "Found the slot to start with", importedSlot

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

      while running and imported < conf.maxBlocks and blockNumber <= lastEra1Block:
        var blk = db.getEthBlock(blockNumber).valueOr:
          error "Could not load block from era1", blockNumber, error
          break

        imported += 1
        blocks.add move(blk)

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
      if blockNumber > lastEra1Block + 1:
        updateLastImportedSlot(
          eraDB, historical_roots.asSeq(), historical_summaries.asSeq()
        )

      if importedSlot < firstSlotAfterMerge and firstSlotAfterMerge != 0:
        # if resuming import we do not update the slot
        importedSlot = firstSlotAfterMerge

      while running and imported < conf.maxBlocks and importedSlot < endSlot:
        let clblock = getBlockFromEra(
          eraDB,
          historical_roots.asSeq(),
          historical_summaries.asSeq(),
          Slot(importedSlot),
          clConfig.cfg,
        ).valueOr:
          importedSlot += 1
          continue

        blocks.add getEth1Block(clblock)
        imported += 1

        importedSlot += 1
        if blocks.lenu64 mod conf.chunkSize == 0:
          process()

      if blocks.len > 0:
        process()

  for blocksFile in conf.blocksFile:
    if isFile(string blocksFile):
      # success or not, we quit after importing blocks
      if not importRlpBlock(string blocksFile, com):
        quit(QuitFailure)
      else:
        quit(QuitSuccess)
