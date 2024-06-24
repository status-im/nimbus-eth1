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
  ./config,
  ./common/common,
  ./core/[block_import, chain],
  ./db/era1_db,
  beacon_chain/era_db

declareGauge nec_import_block_number,
  "Latest imported block number"

declareCounter nec_imported_blocks,
  "Blocks processed during import"

declareCounter nec_imported_transactions,
  "Transactions processed during import"

declareCounter nec_imported_gas,
  "Gas processed during import"

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
    gas = GasInt(0)
    txs = 0
    time0 = Moment.now()
    csv =
      if conf.csvStats.isSome:
        try:
          let f = open(conf.csvStats.get(), fmAppend)
          if f.getFileSize() == 0:
            f.writeLine("block_number,blocks,txs,gas,time")
          f
        except IOError as exc:
          error "Could not open statistics output file",
            file = conf.csvStats, err = exc.msg
          quit(QuitFailure)
      else:
        File(nil)
    flags =
      boolFlag({PersistBlockFlag.NoFullValidation}, not conf.fullValidation) +
      boolFlag(NoPersistBodies, not conf.storeBodies) +
      boolFlag({PersistBlockFlag.NoPersistReceipts}, not conf.storeReceipts)

  defer:
    if csv != nil:
      close(csv)

  nec_import_block_number.set(start.int64)

  template blockNumber(): uint64 =
    start + imported

  if isDir(conf.era1Dir.string):
    doAssert conf.networkId == MainNet, "Only mainnet era1 current supported"

    const
      # TODO the merge block number could be fetched from the era1 file instead,
      #      specially if the accumulator is added to the chain metadata
      lastEra1Block = 15537393

    if start <= lastEra1Block:
      notice "Importing era1 archive",
        start, dataDir = conf.dataDir.string, era1Dir = conf.era1Dir.string
      var blocks: seq[EthBlock]

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
        nec_imported_gas.inc(statsRes[].gas)

        if csv != nil:
          # In the CSV, we store a line for every chunk of blocks processed so
          # that the file can meaningfully be appended to when restarting the
          # process - this way, each sample is independent
          try:
            csv.writeLine(
              [
                $blockNumber,
                $blocks.len,
                $statsRes[].txs,
                $statsRes[].gas,
                $(time2 - time1).nanoseconds(),
              ].join(",")
            )
            csv.flushFile()
          except IOError as exc:
            warn "Could not write csv", err = exc.msg
        blocks.setLen(0)

      let db =
        Era1DbRef.init(conf.era1Dir.string, "mainnet").expect("Era files present")
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

  for blocksFile in conf.blocksFile:
    if isFile(string blocksFile):
      # success or not, we quit after importing blocks
      if not importRlpBlock(string blocksFile, com):
        quit(QuitFailure)
      else:
        quit(QuitSuccess)
