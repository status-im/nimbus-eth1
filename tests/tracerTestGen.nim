import
  json, os, eth_common, stint, chronicles,
  eth_trie/[db], ../nimbus/db/[db_chain, capturedb],
  ../nimbus/[tracer, vm_types, config]

const backEnd {.strdefine.} = "lmdb"

when backEnd == "sqlite":
  import ../nimbus/db/backends/sqlite_backend
elif backEnd == "rocksdb":
  import ../nimbus/db/backends/rocksdb_backend
else:
  import ../nimbus/db/backends/lmdb_backend

proc dumpTest(chainDB: BaseChainDB, blockNumber: int) =
  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(chainDB.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)

  var blockNumber = blockNumber.u256
  var header = captureChainDB.getBlockHeader(blockNumber)
  var headerHash = header.blockHash
  var blockBody = captureChainDB.getBlockBody(headerHash)

  let txTrace = traceTransaction(captureChainDB, header, blockBody, 0, {DisableState})
  let stateDump = dumpBlockState(captureChainDB, header, blockBody)
  let blockTrace = traceBlock(captureChainDB, header, blockBody, {DisableState})

  var testData = %{"blockNumber": %blockNumber.toHex, "txTrace": txTrace, "stateDump": stateDump, "blockTrace": blockTrace}
  testData.dumpMemoryDB(memoryDB)
  writeFile("block" & $blockNumber & ".json", testData.pretty())

proc main() =
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

main()
