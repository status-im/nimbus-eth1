import
  json, chronicles,
  ../nimbus/db/[capturedb, select_backend],
  ../nimbus/[config, vm_types],
  ../nimbus/tracer,
  ../nimbus/common/common

proc dumpTest(com: CommonRef, blockNumber: int) =
  let
    blockNumber = blockNumber.u256

  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(com.db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureCom = com.clone(captureTrieDB)

  let
    header = captureCom.db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = captureCom.db.getBlockBody(headerHash)
    txTrace = traceTransactions(captureCom, header, blockBody)
    stateDump = dumpBlockState(captureCom, header, blockBody)
    blockTrace = traceBlock(captureCom, header, blockBody, {DisableState})
    receipts = dumpReceipts(captureCom.db, header)

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": txTrace,
    "stateDump": stateDump,
    "blockTrace": blockTrace,
    "receipts": receipts
  }

  metaData.dumpMemoryDB(memoryDB)
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
  let db = newChainDB(string conf.dataDir)
  let trieDB = trieDB db
  let com = CommonRef.new(trieDB, false)

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
