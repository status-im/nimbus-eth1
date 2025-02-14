# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  ./core/chain,
  ./db/era1_db,
  ./utils/era_helpers

declareGauge nec_import_block_number, "Latest imported block number"

declareCounter nec_imported_blocks, "Blocks processed during import"

declareCounter nec_imported_transactions, "Transactions processed during import"

declareCounter nec_imported_gas, "Gas processed during import"

var running {.volatile.} = true

proc openCsv(name: string): File =
  try:
    let f = open(name, fmAppend)
    let pos = f.getFileSize()
    if pos == 0:
      f.writeLine("block_number,blocks,slot,txs,gas,time")
    f
  except IOError as exc:
    fatal "Could not open statistics output file", file = name, err = exc.msg
    quit(QuitFailure)

proc getMetadata(networkId: NetworkId): auto =
  # Network Specific Configurations
  # TODO: the merge block number could be fetched from the era1 file instead,
  #       specially if the accumulator is added to the chain metadata
  case networkId
  of MainNet:
    (
      getMetadataForNetwork("mainnet").cfg,
      # Mainnet Validators Root
      Eth2Digest.fromHex(
        "0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95"
      ),
      15537393'u64, # Last pre-merge block
      4700013'u64, # First post-merge slot
    )
  of SepoliaNet:
    (
      getMetadataForNetwork("sepolia").cfg,
      Eth2Digest.fromHex(
        "0xd8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078"
      ),
      1450408'u64, # Last pre-merge block number
      115193'u64, # First post-merge slot
    )
  of HoleskyNet:
    (
      getMetadataForNetwork("holesky").cfg,
      Eth2Digest.fromHex(
        "0x9143aa7c615a7f7115e2b6aac319c03529df8242ae705fba9df39b79c59fa8b1"
      ),
      0'u64, # Last pre-merge block number
      0'u64, # First post-merge slot
    )
  else:
    fatal "Unsupported network", network = networkId
    quit(QuitFailure)

template boolFlag(flags, b): PersistBlockFlags =
  if b:
    flags
  else:
    {}

proc importBlocks*(conf: NimbusConf, com: CommonRef) =
  proc controlCHandler() {.noconv.} =
    when defined(windows):
      # workaround for https://github.com/nim-lang/Nim/issues/4057
      setupForeignThreadGc()
    running = false

  setControlCHook(controlCHandler)

  let
    start = com.db.baseTxFrame().getSavedStateBlockNumber() + 1
    chain = com.newChain()
    (cfg, genesis_validators_root, lastEra1Block, firstSlotAfterMerge) =
      getMetadata(conf.networkId)
    time0 = Moment.now()

  # These variables are used from closures on purpose, so as to place them on
  # the heap rather than the stack
  var
    slot = 1'u64
    time1 = Moment.now() # time at start of chunk
    csv =
      if conf.csvStats.isSome:
        openCsv(conf.csvStats.get())
      else:
        File(nil)
    flags =
      boolFlag({PersistBlockFlag.NoValidation}, conf.noValidation) +
      boolFlag({PersistBlockFlag.NoFullValidation}, not conf.fullValidation) +
      boolFlag(NoPersistBodies, not conf.storeBodies) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts) +
      boolFlag({PersistBlockFlag.NoPersistSlotHashes}, not conf.storeSlotHashes)
    blk: Block
    persister = Persister.init(chain, flags)
    cstats: PersistStats # stats at start of chunk

  defer:
    if csv != nil:
      close(csv)

  template blockNumber(): uint64 =
    start + uint64 persister.stats.blocks

  nec_import_block_number.set(start.int64)

  func f(value: float): string =
    if value >= 1000:
      &"{int(value)}"
    elif value >= 100:
      &"{value:4.1f}"
    elif value >= 10:
      &"{value:4.2f}"
    else:
      &"{value:4.3f}"

  proc persistBlock() =
    persister.persistBlock(blk).isOkOr:
      fatal "Could not persist block", blockNumber = blk.header.number, error
      quit(QuitFailure)

  proc checkpoint(force: bool = false) =
    let (blocks, txs, gas) = persister.stats

    if not force and blocks.uint64 mod conf.chunkSize != 0:
      return

    persister.checkpoint().isOkOr:
      fatal "Could not write database checkpoint", error
      quit(QuitFailure)

    let (cblocks, ctxs, cgas) =
      (blocks - cstats.blocks, txs - cstats.txs, gas - cstats.gas)

    if cblocks == 0:
      return

    cstats = persister.stats

    let
      time2 = Moment.now()
      diff1 = (time2 - time1).nanoseconds().float / 1000000000
      diff0 = (time2 - time0).nanoseconds().float / 1000000000

    info "Imported blocks",
      blockNumber,
      slot,
      blocks,
      txs,
      mgas = f(gas.float / 1000000),
      bps = f(cblocks.float / diff1),
      tps = f(ctxs.float / diff1),
      mgps = f(cgas.float / 1000000 / diff1),
      avgBps = f(blocks.float / diff0),
      avgTps = f(txs.float / diff0),
      avgMGps = f(gas.float / 1000000 / diff0),
      elapsed = toString(time2 - time0, 3)

    metrics.set(nec_import_block_number, int64(blockNumber))
    nec_imported_blocks.inc(cblocks)
    nec_imported_transactions.inc(ctxs)
    nec_imported_gas.inc(int64 cgas)

    if csv != nil:
      # In the CSV, we store a line for every chunk of blocks processed so
      # that the file can meaningfully be appended to when restarting the
      # process - this way, each sample is independent
      try:
        csv.writeLine(
          [$blockNumber, $cblocks, $slot, $ctxs, $cgas, $(time2 - time1).nanoseconds()].join(
            ","
          )
        )
        csv.flushFile()
      except IOError as exc:
        warn "Could not write csv", err = exc.msg

    time1 = time2

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
      if not getEthBlockFromEra(
        era, historical_roots, historical_summaries, startSlot, cfg, blk
      ):
        startSlot += 1
        if startSlot == endSlot - 1:
          error "No blocks found in the last era file"
          return false

        continue

      startSlot += 1
      if blk.header.number < blockNumber:
        notice "Available `era` files are already imported",
          stateBlockNumber = blockNumber, eraBlockNumber = blk.header.number
        return false
      break

    if blockNumber > 1:
      # Setting the initial lower bound
      slot = (blockNumber - lastEra1Block) + firstSlotAfterMerge
      debug "Finding slot number after resuming import", slot

      # BlockNumber based slot finding
      var clNum = 0'u64

      while clNum < blockNumber:
        if not getEthBlockFromEra(
          era, historical_roots, historical_summaries, Slot(slot), cfg, blk
        ):
          slot += 1
          continue

        clNum = blk.header.number
        # decreasing the lower bound with each iteration
        slot += blockNumber - clNum

      notice "Matched block to slot number", blockNumber, slot
    return true

  if lastEra1Block > 0 and start <= lastEra1Block:
    let
      era1Name =
        case conf.networkId
        of MainNet:
          "mainnet"
        of SepoliaNet:
          "sepolia"
        else:
          raiseAssert "Other networks are unsupported or do not have an era1"
      db = Era1DbRef.init(conf.era1Dir.string, era1Name).valueOr:
        fatal "Could not open era1 database", era1Dir=conf.era1Dir, era1Name=era1Name, error=error
        quit(QuitFailure)

    notice "Importing era1 archive",
      start, dataDir = conf.dataDir.string, era1Dir = conf.era1Dir.string

    defer:
      db.dispose()

    proc loadEraBlock(blockNumber: uint64): bool =
      db.getEthBlock(blockNumber, blk).isOkOr:
        return false
      true

    while running and persister.stats.blocks.uint64 < conf.maxBlocks and
        blockNumber <= lastEra1Block:
      if not loadEraBlock(blockNumber):
        notice "No more `era1` blocks to import", blockNumber, slot
        break
      persistBlock()
      checkpoint()

  block era1Import:
    if blockNumber > lastEra1Block:
      if not isDir(conf.eraDir.string):
        if blockNumber == 0:
          fatal "`era` directory not found, cannot start import",
            blockNumber, eraDir = conf.eraDir.string
          quit(QuitFailure)
        else:
          notice "`era` directory not found, stopping import at merge boundary",
            blockNumber, eraDir = conf.eraDir.string
          break era1Import

      notice "Importing era archive",
        blockNumber, dataDir = conf.dataDir.string, eraDir = conf.eraDir.string

      let
        eraDB = EraDB.new(cfg, conf.eraDir.string, genesis_validators_root)
        (historical_roots, historical_summaries, endSlot) = loadHistoricalRootsFromEra(
          conf.eraDir.string, cfg
        ).valueOr:
          fatal "Could not load historical summaries",
            eraDir = conf.eraDir.string, error
          quit(QuitFailure)

      # Load the last slot number
      var moreEraAvailable = true
      if blockNumber > lastEra1Block + 1:
        moreEraAvailable = updateLastImportedSlot(
          eraDB, historical_roots.asSeq(), historical_summaries.asSeq(), endSlot
        )

      if slot < firstSlotAfterMerge and firstSlotAfterMerge != 0:
        # if resuming import we do not update the slot
        slot = firstSlotAfterMerge

      proc loadEra1Block(): bool =
        # Separate proc to reduce stack usage of blk
        if not getEthBlockFromEra(
          eraDB,
          historical_roots.asSeq(),
          historical_summaries.asSeq(),
          Slot(slot),
          cfg,
          blk,
        ):
          return false

        true

      while running and moreEraAvailable and
          persister.stats.blocks.uint64 < conf.maxBlocks and slot < endSlot:
        if not loadEra1Block():
          slot += 1
          continue
        slot += 1

        persistBlock()
        checkpoint()

  # There is some fringe case where the `persister` is not in sync to the DB
  # state. Checkpointing here would then produce a mismatch of the
  # `getSavedStateBlockNumber()` value and the state which typically fails
  # with a state root mismatch when the next program uses the DB.
  #
  # This all happens only if there were no `era` or `era1` files that could be
  # imported.
  if 0 < persister.stats.blocks:
    checkpoint(true)

  notice "Import complete",
    blockNumber,
    slot,
    blocks = persister.stats.blocks,
    txs = persister.stats.txs,
    mgas = f(persister.stats.gas.float / 1000000)
