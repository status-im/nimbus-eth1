# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils],
  results,
  ../nimbus/common/common, # must be early (compilation annoyance)
  ../nimbus/db/opts,
  ../nimbus/db/core_db/persistent,
  ../nimbus/[config, tracer, evm/types]

proc dumpTest(com: CommonRef, blockNumber: BlockNumber) =
  var
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)

  let
    blk = captureCom.db.getEthBlock(blockNumber)
    txTrace = traceTransactions(captureCom, blk.header, blk.transactions)
    stateDump = dumpBlockState(captureCom, blk)
    blockTrace = traceBlock(captureCom, blk, {DisableState})
    receipts = dumpReceipts(captureCom.db, blk.header)

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": txTrace,
    "stateDump": stateDump,
    "blockTrace": blockTrace,
    "receipts": receipts
  }

  metaData.dumpMemoryDB(capture)
  writeFile("block" & $blockNumber & ".json", metaData.pretty())

proc main() {.used.} =
  # 97 block with uncles
  # 46147 block with first transaction
  # 46400 block with transaction
  # 46402 block with first contract: failed
  # 47205 block with first success contract
  # 48712 block with 5 transactions
  # 48915 block with contract
  # 49018 first problematic block
  # 52029 first block with receipts logs
  # 66407 failed transaction

  # nimbus --rpc-api: eth, debug --prune: archive

  var conf = makeConfig()
  let db = newCoreDbRef(
    DefaultDbPersistent, string conf.dataDir, DbOptions.init())
  let com = CommonRef.new(db)

  com.dumpTest(97)
  com.dumpTest(46147)
  com.dumpTest(46400)
  com.dumpTest(46402)
  com.dumpTest(47205)
  com.dumpTest(48712)
  com.dumpTest(48915)
  com.dumpTest(49018)

when isMainModule:
  try:
    main()
  except:
    echo getCurrentExceptionMsg()
