import
  json, os, eth_common, stint, chronicles, byteutils, nimcrypto, rlp,
  eth_trie/[db], ../nimbus/db/[db_chain, capturedb, storage_types, select_backend],
  ../nimbus/[tracer, vm_types, config],
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
  chainDB.dumpTest(98) # not uncles and no tx
  chainDB.dumpTest(46147)
  chainDB.dumpTest(46400)
  chainDB.dumpTest(46402)
  chainDB.dumpTest(47205)
  chainDB.dumpTest(48712)
  chainDB.dumpTest(48915)

main()
