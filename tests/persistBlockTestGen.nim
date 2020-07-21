import
  json, eth/common, stint, chronicles, eth/rlp,
  eth/trie/db, ../nimbus/db/[db_chain, capturedb, select_backend],
  ../nimbus/[tracer, config],
  ../nimbus/p2p/chain

proc dumpTest(chainDB: BaseChainDB, blockNumber: int) =
  let
    blockNumber = blockNumber.u256
    parentNumber = blockNumber - 1

  var
    memoryDB = newMemoryDB()
    captureDB = newCaptureDB(chainDB.db, memoryDB)
    captureTrieDB = trieDB captureDB
    captureChainDB = newBaseChainDB(captureTrieDB, false)

  let
    parent = captureChainDB.getBlockHeader(parentNumber)
    header = captureChainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = captureChainDB.getBlockBody(headerHash)
    chain = newChain(captureChainDB)
    headers = @[header]
    bodies = @[blockBody]

  captureChainDB.setHead(parent, true)
  discard chain.persistBlocks(headers, bodies)

  var metaData = %{
    "blockNumber": %blockNumber.toHex
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
  chainDB.dumpTest(98) # no uncles and no tx
  chainDB.dumpTest(46147)
  chainDB.dumpTest(46400)
  chainDB.dumpTest(46402)
  chainDB.dumpTest(47205)
  chainDB.dumpTest(48712)
  chainDB.dumpTest(48915)
  chainDB.dumpTest(49018)
  chainDB.dumpTest(49439) # call opcode bug
  chainDB.dumpTest(49891) # number opcode bug
  chainDB.dumpTest(50111) # apply message bug
  chainDB.dumpTest(78458 )
  chainDB.dumpTest(81383 ) # tracer gas cost, stop opcode
  chainDB.dumpTest(81666 ) # create opcode
  chainDB.dumpTest(85858 ) # call oog
  chainDB.dumpTest(116524) # codecall address
  chainDB.dumpTest(146675) # precompiled contracts ecRecover
  chainDB.dumpTest(196647) # not enough gas to call
  chainDB.dumpTest(226147) # create return gas
  chainDB.dumpTest(226522) # return
  chainDB.dumpTest(231501) # selfdestruct
  chainDB.dumpTest(243826) # create contract self destruct
  chainDB.dumpTest(248032) # signextend over/undeflow
  chainDB.dumpTest(299804) # GasInt overflow
  chainDB.dumpTest(420301) # computation gas cost LTE(<=) 0 to LT(<) 0
  chainDB.dumpTest(512335) # create apply message
  chainDB.dumpTest(47216)   # regression
  chainDB.dumpTest(652148)  # contract transfer bug
  chainDB.dumpTest(668910)  # uncleared logs bug
  chainDB.dumpTest(1_017_395) # sha256 and ripemd precompiles wordcount bug
  chainDB.dumpTest(1_149_150) # need to swallow precompiles errors
  chainDB.dumpTest(1_155_095) # homestead codeCost OOG
  chainDB.dumpTest(1_317_742) # CREATE childmsg sender
  chainDB.dumpTest(1_352_922) # first ecrecover precompile with 0x0 input
  chainDB.dumpTest(1_368_834) # writepadded regression padding len
  chainDB.dumpTest(1_417_555) # writepadded regression zero len
  chainDB.dumpTest(1_431_916) # deep recursion stack overflow problem
  chainDB.dumpTest(1_487_668) # getScore uint64 vs uint256 overflow
  chainDB.dumpTest(1_920_000) # the DAO fork
  chainDB.dumpTest(1_927_662) # fork comparison bug in postExecuteVM

  # too big and too slow, we can skip it
  # because it already covered by GST
  #chainDB.dumpTest(2_283_416) # first DDOS spam attack block
  chainDB.dumpTest(2_463_413) # tangerine call* gas cost bug
  chainDB.dumpTest(2_675_000) # spurious dragon first block
  chainDB.dumpTest(2_675_002) # EIP155 tx.getSender
  chainDB.dumpTest(4_370_000) # Byzantium first block

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
