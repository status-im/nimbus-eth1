import
  json, downloader, stint, eth_trie/db, byteutils,
  ../nimbus/db/[db_chain, storage_types], rlp, eth_common,
  ../nimbus/p2p/chain, ../nimbus/tracer

proc generatePrestate*(nimbus, geth: JsonNode, blockNumber: Uint256, parent, header: BlockHeader, body: BlockBody) =
  let
    state = nimbus["state"]
    headerHash = rlpHash(header)
    #parentNumber = parent.blockNumber

  var
    memoryDB = newMemoryDB()
    chainDB = newBaseChainDB(memoryDB, false)

  chainDB.setHead(parent, true)
  chainDB.persistTransactions(blockNumber, body.transactions)
  discard chainDB.persistUncles(body.uncles)

  memoryDB.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))
  chainDB.addBlockNumberToHashLookup(header)

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

  #discard chainDB.getBlockHeader(parentNumber)
  #discard chainDB.getBlockHeader(blockNumber)
  #discard chainDB.getBlockBody(headerHash)

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "geth": geth
  }

  metaData.dumpMemoryDB(memoryDB)
  writeFile("block" & $blockNumber & ".json", metaData.pretty())
