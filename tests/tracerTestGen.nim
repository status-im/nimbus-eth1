import
  json, eth/common, stint, chronicles,
  eth/trie/db, ../nimbus/db/[db_chain, capturedb, select_backend],
  ../nimbus/[tracer, vm_types, config]

proc dumpTest(chainDB: BaseChainDB, blockNumber: int) =
  let
    blockNumber = blockNumber.u256

  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(chainDB.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)

  let
    header = captureChainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = captureChainDB.getBlockBody(headerHash)
    txTrace = traceTransactions(captureChainDB, header, blockBody)
    stateDump = dumpBlockState(captureChainDB, header, blockBody)
    blockTrace = traceBlock(captureChainDB, header, blockBody, {DisableState})
    receipts = dumpReceipts(captureChainDB, header)

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

  # nimbus --rpcapi: eth, debug --prune: archive

  var conf = getConfiguration()
  let db = newChainDb(conf.dataDir)
  let trieDB = trieDB db
  let chainDB = newBaseChainDB(trieDB, false)

  chainDB.dumpTest(97)
  chainDB.dumpTest(46147)
  chainDB.dumpTest(46400)
  chainDB.dumpTest(46402)
  chainDB.dumpTest(47205)
  chainDB.dumpTest(48712)
  chainDB.dumpTest(48915)
  chainDB.dumpTest(49018)

when isMainModule:
  var message: string

  ## Processing command line arguments
  if processArguments(message) != Success:
    echo message
    quit(QuitFailure)
  else:
    if len(message) > 0:
      echo message
      quit(QuitSuccess)

  try:
    main()
  except:
    echo getCurrentExceptionMsg()
