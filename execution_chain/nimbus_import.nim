# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
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
  beacon_chain/process_state,
  ./conf,
  ./common/common,
  ./core/chain,
  ../portal/database/ere_db

declareGauge nec_import_block_number, "Latest imported block number"

declareCounter nec_imported_blocks, "Blocks processed during import"

declareCounter nec_imported_transactions, "Transactions processed during import"

declareCounter nec_imported_gas, "Gas processed during import"

proc openCsv(name: string): File =
  try:
    let f = open(name, fmAppend)
    let pos = f.getFileSize()
    if pos == 0:
      f.writeLine("block_number,blocks,txs,gas,time")
    f
  except IOError as exc:
    fatal "Could not open statistics output file", file = name, err = exc.msg
    quit(QuitFailure)

proc getMetadata(networkId: NetworkId): tuple[networkName: string, mergeBlockNumber: uint64] =
  if networkId == MainNet:
    ("mainnet", 15537394'u64)
  elif networkId == SepoliaNet:
    ("sepolia", 1450409'u64)
  elif networkId == HoodiNet:
    ("hoodi", 1'u64)
  else:
    fatal "Unsupported network", network = networkId
    quit(QuitFailure)

template boolFlag(flags, b): PersistBlockFlags =
  if b:
    flags
  else:
    {}

proc running(): bool =
  not ProcessState.stopIt(notice("Shutting down", reason = it))

proc importBlocks*(config: ExecutionClientConf, com: CommonRef) =
  let
    start = com.db.baseTxFrame().getSavedStateBlockNumber() + 1
    (networkName, mergeBlockNumber) = getMetadata(config.networkId)
    time0 = Moment.now()

  # These variables are used from closures on purpose, so as to place them on
  # the heap rather than the stack
  var
    time1 = Moment.now() # time at start of chunk
    csv =
      if config.csvStats.isSome:
        openCsv(config.csvStats.get())
      else:
        File(nil)
    flags =
      boolFlag({PersistBlockFlag.Validation}, config.validation) +
      boolFlag({PersistBlockFlag.FullValidation}, config.fullValidation) +
      boolFlag({PersistBlockFlag.PersistHeaders}, true) +
      boolFlag(PersistBodies, config.storeBodies) +
      boolFlag({PersistBlockFlag.PersistReceipts}, config.storeReceipts) +
      boolFlag({PersistBlockFlag.PersistSlotHashes}, config.storeSlotHashes)
    blk: Block
    persister = Persister.init(com, flags)
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

    if not force and blocks.uint64 mod config.chunkSize != 0:
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
      try:
        csv.writeLine(
          [$blockNumber, $cblocks, $ctxs, $cgas, $(time2 - time1).nanoseconds()].join(",")
        )
        csv.flushFile()
      except IOError as exc:
        warn "Could not write csv", err = exc.msg

    time1 = time2

  let db = EreDB.init(config.ereDir, networkName, mergeBlockNumber).valueOr:
    fatal "Could not open ere database",
      ereDir = config.ereDir, networkName, error = error
    quit(QuitFailure)
  defer:
    db.dispose()

  notice "Importing ere archive",
    start, dataDir = config.dataDir, ereDir = config.ereDir

  proc loadEreBlock(blockNumber: uint64): bool =
    db.getEthBlock(blockNumber, blk).isOkOr:
      debug "Era block not found", blockNumber, msg = error
      return false
    true

  while running() and persister.stats.blocks.uint64 < config.maxBlocks:
    if not loadEreBlock(blockNumber):
      notice "No more `ere` blocks to import", blockNumber
      break
    persistBlock()
    checkpoint()

  # If there were no blocks written, we will not have loaded the block number
  # and therefore should not call checkpoint().
  if 0 < persister.stats.blocks:
    checkpoint(true)

  notice "Import complete",
    blockNumber,
    blocks = persister.stats.blocks,
    txs = persister.stats.txs,
    mgas = f(persister.stats.gas.float / 1000000)
