import
  eth/[common, rlp], stint,
  chronicles, configuration,
  eth/trie/[hexary, db]

import
  ../nimbus/db/[db_chain, select_backend],
  ../nimbus/vm_state,
  ../nimbus/p2p/executor

const
  numBlocks = 256

proc validateBlock(chainDB: BaseChainDB, blockNumber: BlockNumber): BlockNumber =
  var
    parentNumber = blockNumber - 1
    parent = chainDB.getBlockHeader(parentNumber)
    headers = newSeq[BlockHeader](numBlocks)
    bodies  = newSeq[BlockBody](numBlocks)

  for i in 0 ..< numBlocks:
    headers[i] = chainDB.getBlockHeader(blockNumber + i.u256)
    bodies[i]  = chainDB.getBlockBody(headers[i].blockHash)

  let transaction = chainDB.db.beginTransaction()
  defer: transaction.dispose()

  for i in 0 ..< numBlocks:
    stdout.write blockNumber + i.u256
    stdout.write "\r"

    let
      vmState = newBaseVMState(parent.stateRoot, headers[i], chainDB)
      validationResult = processBlock(chainDB, headers[i], bodies[i], vmState)

    if validationResult != ValidationResult.OK:
      error "block validation error", validationResult, blockNumber = blockNumber + i.u256

    parent = headers[i]

  transaction.rollback()
  result = blockNumber + numBlocks.u256

proc main() {.used.} =
  let
    conf = getConfiguration()
    db = newChainDb(conf.dataDir)
    trieDB = trieDB db
    chainDB = newBaseChainDB(trieDB, false)

  # move head to block number ...
  if conf.head == 0.u256:
    raise newException(ValueError, "please set block number with --head: blockNumber")

  var counter = 0
  var blockNumber = conf.head

  while true:
    blockNumber = chainDB.validateBlock(blockNumber)

    inc counter
    if conf.maxBlocks != 0 and counter >= conf.maxBlocks:
      break

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
