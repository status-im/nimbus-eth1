#
# helper tool to dump debugging data for persisted block
# usage: dumper [--datadir:your_path] --head:blockNumber
#

import
  configuration, stint, eth_common,
  ../nimbus/db/[storage_types, db_chain, select_backend, capturedb],
  eth_trie/[hexary, db, defs], ../nimbus/p2p/executor,
  ../nimbus/[tracer, vm_state]

proc dumpDebug(chainDB: BaseChainDB, blockNumber: Uint256) =
  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(chainDB.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)

  let
    parentNumber = blockNumber - 1
    parent = captureChainDB.getBlockHeader(parentNumber)
    header = captureChainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = captureChainDB.getBlockBody(headerHash)
    vmState = newBaseVMState(parent, captureChainDB)

  captureChainDB.setHead(parent, true)
  let validationResult = processBlock(captureChainDB, parent, header, body, vmState)
  dumpDebuggingMetaData(captureChainDB, header, body, vmState.receipts)

proc main() =
  let conf = getConfiguration()
  let db = newChainDb(conf.dataDir)
  let trieDB = trieDB db
  let chainDB = newBaseChainDB(trieDB, false)

  if conf.head != 0.u256:
    dumpDebug(chainDB, conf.head)

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
