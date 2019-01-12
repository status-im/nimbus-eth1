import
  json, os, stint, eth_trie/db, byteutils, eth_common,
  ../nimbus/db/[db_chain], chronicles, ../nimbus/vm_state,
  ../nimbus/p2p/executor

proc prepareBlockEnv(node: JsonNode, memoryDB: TrieDatabaseRef) =
  let state = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

proc executeBlock(memoryDB: TrieDatabaseRef, blockNumber: Uint256) =
  let
    parentNumber = blockNumber - 1
    chainDB = newBaseChainDB(memoryDB, false)
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    body   = chainDB.getBlockBody(header.blockHash)

  let
    vmState = newBaseVMState(parent, chainDB)
    validationResult = processBlock(chainDB, parent, header, body, vmState)

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
