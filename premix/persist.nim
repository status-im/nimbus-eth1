# use this module to quickly populate db with data from geth/parity

import
  eth_common, stint, byteutils, nimcrypto,
  chronicles, rlp, downloader, configuration,
  ../nimbus/errors

import
  eth_trie/[hexary, db, defs],
  ../nimbus/db/[storage_types, db_chain, select_backend],
  ../nimbus/[genesis, utils],
  ../nimbus/p2p/chain

const
  manualCommit = nimbus_db_backend == "lmdb"

template persistToDb(db: ChainDB, body: untyped) =
  when manualCommit:
    if not db.txBegin(): assert(false)
  body
  when manualCommit:
    if not db.txCommit(): assert(false)

proc main() =
  # 97 block with uncles
  # 46147 block with first transaction
  # 46400 block with transaction
  # 46402 block with first contract: failed
  # 47205 block with first success contract
  # 48712 block with 5 transactions
  # 48915 block with contract
  # 49018 first problematic block
  # 49439 first block with contract call
  # 52029 first block with receipts logs
  # 66407 failed transaction

  let conf = getConfiguration()
  let db = newChainDb(conf.dataDir)
  let trieDB = trieDB db
  let chainDB = newBaseChainDB(trieDB, false)

  # move head to block number ...
  if conf.head != 0.u256:
    var parentBlock = requestBlock(conf.head)
    chainDB.setHead(parentBlock.header)

  if canonicalHeadHashKey().toOpenArray notin trieDB:
    persistToDb(db):
      initializeEmptyDb(chainDB)
    assert(canonicalHeadHashKey().toOpenArray in trieDB)

  var head = chainDB.getCanonicalHead()
  var blockNumber = head.blockNumber + 1
  var chain = newChain(chainDB)

  let numBlocksToCommit = conf.numCommits

  var headers = newSeqOfCap[BlockHeader](numBlocksToCommit)
  var bodies  = newSeqOfCap[BlockBody](numBlocksToCommit)
  var one     = 1.u256

  var numBlocks = 0
  var counter = 0

  while true:
    info "REQUEST HEADER", blockNumber=blockNumber
    var thisBlock = requestBlock(blockNumber)

    headers.add thisBlock.header
    bodies.add thisBlock.body
    inc numBlocks
    blockNumber += one

    if numBlocks == numBlocksToCommit:
      persistToDb(db):
        if chain.persistBlocks(headers, bodies) != ValidationResult.OK:
          raise newException(ValidationError, "Error when validating blocks")
      numBlocks = 0
      headers.setLen(0)
      bodies.setLen(0)

    inc counter
    if conf.maxBlocks != 0 and counter >= conf.maxBlocks:
      break

  if numBlocks > 0:
    persistToDb(db):
      if chain.persistBlocks(headers, bodies) != ValidationResult.OK:
        raise newException(ValidationError, "Error when validating blocks")

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
