import
  json, os, stint, eth_trie/db, byteutils, eth_common,
  ../nimbus/db/[db_chain], ../nimbus/p2p/chain,
  chronicles

proc prepareBlockEnv(node: JsonNode, memoryDB: TrieDatabaseRef) =
  let state = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

proc executeBlock(memoryDB: TrieDatabaseRef, blockNumber: Uint256) =
  let
    chainDB = newBaseChainDB(memoryDB, false)
    parentNumber = blockNumber - 1
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body    = chainDB.getBlockBody(headerHash)
    chain   = newChain(chainDB)
    headers = @[header]
    bodies  = @[body]

  chainDB.setHead(parent, true)
  let validationResult = chain.persistBlocks(headers, bodies)
  if validationResult != ValidationResult.OK:
    error "block validation error", validationResult
  else:
    info "block validation success", validationResult, blockNumber

proc main() =
  if paramCount() == 0:
    echo "usage: debug blockxxx.json"
    quit(QuitFailure)

  let
    blockEnv = json.parseFile(paramStr(1))
    memoryDB = newMemoryDB()
    blockNumber = UInt256.fromHex(blockEnv["blockNumber"].getStr())

  prepareBlockEnv(blockEnv, memoryDB)
  executeBlock(memoryDB, blockNumber)

main()
