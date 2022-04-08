#
# helper tool to dump debugging data for persisted block
# usage: dumper [--datadir:your_path] --head:blockNumber
#

import
  configuration, stint, eth/common,
  ../nimbus/db/[db_chain, select_backend, capturedb],
  eth/trie/[hexary, db], ../nimbus/p2p/executor,
  ../nimbus/[tracer, vm_state, vm_types]

proc dumpDebug(chainDB: BaseChainDB, blockNumber: UInt256) =
  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(chainDB.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)

  let transaction = memoryDB.beginTransaction()
  defer: transaction.dispose()


  let
    parentNumber = blockNumber - 1
    parent = captureChainDB.getBlockHeader(parentNumber)
    header = captureChainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = captureChainDB.getBlockBody(headerHash)
    vmState = BaseVMState.new(parent, header, captureChainDB)

  captureChainDB.setHead(parent, true)
  discard vmState.processBlockNotPoA(header, body)

  transaction.rollback()
  dumpDebuggingMetaData(captureChainDB, header, body, vmState, false)

proc main() {.used.} =
  let conf = getConfiguration()
  let db = newChainDB(conf.dataDir)
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
