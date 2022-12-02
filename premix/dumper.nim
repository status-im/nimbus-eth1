#
# helper tool to dump debugging data for persisted block
# usage: dumper [--datadir:your_path] --head:blockNumber
#

import
  configuration, stint,
  eth/trie/hexary,
  ../nimbus/db/[select_backend, capturedb],
  ../nimbus/common/common,
  ../nimbus/core/executor,
  ../nimbus/[vm_state, vm_types],
  ../nimbus/tracer

proc dumpDebug(com: CommonRef, blockNumber: UInt256) =
  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(com.db.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureCom = com.clone(captureTrieDB)

  let transaction = memoryDB.beginTransaction()
  defer: transaction.dispose()


  let
    parentNumber = blockNumber - 1
    parent = captureCom.db.getBlockHeader(parentNumber)
    header = captureCom.db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = captureCom.db.getBlockBody(headerHash)
    vmState = BaseVMState.new(parent, header, captureCom)

  discard captureCom.db.setHead(parent, true)
  discard vmState.processBlockNotPoA(header, body)

  transaction.rollback()
  dumpDebuggingMetaData(captureCom, header, body, vmState, false)

proc main() {.used.} =
  let conf = getConfiguration()
  let db = newChainDB(conf.dataDir)
  let trieDB = trieDB db
  let com = CommonRef.new(trieDB, false)

  if conf.head != 0.u256:
    dumpDebug(com, conf.head)

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
