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
  chronos/timer,
  std/strformat,
  stew/io2,
  ./config,
  ./common/common,
  ./core/[block_import, chain],
  ./db/era1_db,
  beacon_chain/era_db

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
      if v == 0 or parts <= 0: return res

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
    start = try:
      com.db.getSavedStateBlockNumber().truncate(uint64) + 1
    except RlpError as exc:
      error "Could not read block number", err = exc.msg
      quit(QuitFailure)

    chain = com.newChain()

  var
    imported = 0'u64
    gas = 0.u256
    txs = 0
    time0 = Moment.now()
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
      var
        headers: seq[BlockHeader]
        bodies: seq[BlockBody]

      func f(value: float): string =
        try:
          &"{value:4.3f}"
        except ValueError:
          raiseAssert "valid fmt string"

      template process() =
        let
          time1 = Moment.now()
          statsRes = chain.persistBlocks(headers, bodies)
        if statsRes.isErr():
          error "Failed to persist blocks", error = statsRes.error
          quit(QuitFailure)

        txs += statsRes[].txs
        gas += uint64 statsRes[].gas
        let
          time2 = Moment.now()
          diff1 = (time2 - time1).nanoseconds().float / 1000000000
          diff0 = (time2 - time0).nanoseconds().float / 1000000000

        # TODO generate csv with import statistics
        info "Imported blocks",
          blockNumber,
          blocks = headers.len,
          txs,
          gas,
          bps = f(headers.len.float / diff1),
          tps = f(statsRes[].txs.float / diff1),
          gps = f(statsRes[].gas.float / diff1),
          totBlocks = imported,
          avgBps = f(imported.float / diff0),
          avgTps = f(txs.float / diff0),
          avgGps = f(gas.truncate(uint64).float / diff0), # TODO fix truncate
          elapsed = shortLog(time2-time1, 3),
          totElapsed = shortLog(time2-time0, 3)
        headers.setLen(0)
        bodies.setLen(0)

      let db =
        Era1DbRef.init(conf.era1Dir.string, "mainnet").expect("Era files present")
      defer:
        db.dispose()

      while running and imported < conf.maxBlocks and blockNumber <= lastEra1Block:
        var blk = db.getBlockTuple(blockNumber).valueOr:
          error "Could not load block from era1", blockNumber, error
          break

        imported += 1

        headers.add move(blk.header)
        bodies.add move(blk.body)

        if headers.lenu64 mod conf.chunkSize == 0:
          process()

      if headers.len > 0:
        process() # last chunk, if any

  for blocksFile in conf.blocksFile:
    if isFile(string blocksFile):
      # success or not, we quit after importing blocks
      if not importRlpBlock(string blocksFile, com):
        quit(QuitFailure)
      else:
        quit(QuitSuccess)
