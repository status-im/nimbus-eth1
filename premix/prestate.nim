import
  json, downloader, stint, eth_trie/db, byteutils,
  ../nimbus/db/[db_chain, storage_types], rlp, eth_common,
  ../nimbus/p2p/chain, ../nimbus/tracer

proc generatePrestate*(nimbus: JsonNode, blockNumber: Uint256, thisBlock: Block) =
  let
    state  = nimbus["state"]
    parentNumber = blockNumber - 1.u256
    parentBlock  = requestBlock(parentNumber)
    headerHash   = rlpHash(thisBlock.header)

  var
    memoryDB = newMemoryDB()
    chainDB = newBaseChainDB(memoryDB, false)

  chainDB.setHead(parentBlock.header, true)
  chainDB.persistTransactions(blockNumber, thisBlock.body.transactions)
  discard chainDB.persistUncles(thisBlock.body.uncles)

  memoryDB.put(genericHashKey(headerHash).toOpenArray, rlp.encode(thisBlock.header))
  chainDB.addBlockNumberToHashLookup(thisBlock.header)

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

  let
    chain = newChain(chainDB)
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    body = chainDB.getBlockBody(headerHash)
    headers = @[header]
    bodies = @[body]

  var metaData = %{
    "blockNumber": %blockNumber.toHex
  }

  metaData.dumpMemoryDB(memoryDB)
  writeFile("block" & $blockNumber & ".json", metaData.pretty())
