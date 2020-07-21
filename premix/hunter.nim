import
  json, downloader, stint, stew/byteutils, parser,
  chronicles, ../nimbus/[tracer, vm_state, utils], eth/trie/[trie_defs, db],
  ../nimbus/db/[db_chain, state_db], ../nimbus/p2p/executor, premixcore,
  eth/common, configuration, tables, ../nimbus/vm_types, hashes

const
  emptyCodeHash = blankStringHash

proc store(memoryDB: TrieDatabaseRef, branch: JsonNode) =
  for p in branch:
    let rlp = hexToSeqByte(p.getStr)
    let hash = keccakHash(rlp)
    memoryDB.put(hash.data, rlp)

proc parseAddress(address: string): EthAddress =
  hexToByteArray(address, result)

proc parseU256(val: string): Uint256 =
  UInt256.fromHex(val)

proc prepareBlockEnv(parent: BlockHeader, thisBlock: Block): TrieDatabaseRef =
  var
    accounts     = requestPostState(thisBlock)
    memoryDB     = newMemoryDB()
    accountDB    = newAccountStateDB(memoryDB, parent.stateRoot, false)
    parentNumber = %(parent.blockNumber.prefixHex)

  for address, account in accounts:
    updateAccount(address, account, parent.blockNumber)
    let
      accountProof = account["accountProof"]
      storageProof = account["storageProof"]
      address      = parseAddress(address)
      acc          = parseAccount(account)

    memoryDB.store(accountProof)
    accountDB.setAccount(address, acc)

    for storage in storageProof:
      let
        key = parseU256(storage["key"].getStr)
        val = parseU256(storage["value"].getStr)
        proof = storage["proof"]
      memoryDB.store(proof)
      accountDB.setStorage(address, key, val)

    if acc.codeHash != emptyCodeHash:
      let codeStr = request("eth_getCode", %[%address.prefixHex, parentNumber])
      let code = hexToSeqByte(codeStr.getStr)
      accountDB.setCode(address, code)

    accountDB.setAccount(address, acc)

  result = memoryDB

type
  HunterVMState = ref object of BaseVMState
    headers: Table[BlockNumber, BlockHeader]

proc hash*(x: Uint256): Hash =
  result = hash(x.toByteArrayBE)

proc newHunterVMState(prevStateRoot: Hash256, header: BlockHeader, chainDB: BaseChainDB): HunterVMState =
  new result
  result.init(prevStateRoot, header, chainDB)
  result.headers = initTable[BlockNumber, BlockHeader]()

method getAncestorHash*(vmState: HunterVMState, blockNumber: BlockNumber): Hash256 {.gcsafe.} =
  if blockNumber in vmState.headers:
    result = vmState.headers[blockNumber].hash
  else:
    let data = requestHeader(blockNumber)
    let header = parseBlockHeader(data)
    result = header.hash
    vmState.headers[blockNumber] = header

proc putAncestorsIntoDB(vmState: HunterVMState, db: BaseChainDB) =
  for header in vmState.headers.values:
    db.addBlockNumberToHashLookup(header)

proc huntProblematicBlock(blockNumber: Uint256): ValidationResult =
  let
    # prepare needed state from previous block
    parentNumber = blockNumber - 1
    thisBlock    = requestBlock(blockNumber)
    parentBlock  = requestBlock(parentNumber)
    memoryDB     = prepareBlockEnv(parentBlock.header, thisBlock)

    # try to execute current block
    chainDB = newBaseChainDB(memoryDB, false)

  chainDB.setHead(parentBlock.header, true)

  let transaction = memoryDB.beginTransaction()
  defer: transaction.dispose()
  let
    vmState = newHunterVMState(parentBlock.header.stateRoot, thisBlock.header, chainDB)
    validationResult = processBlock(chainDB, thisBlock.header, thisBlock.body, vmState)

  if validationResult != ValidationResult.OK:
    transaction.rollback()
    putAncestorsIntoDB(vmState, chainDB)
    dumpDebuggingMetaData(chainDB, thisBlock.header, thisBlock.body, vmState, false)

  result = validationResult

proc main() {.used.} =
  let conf = getConfiguration()

  if conf.head == 0.u256:
    echo "please specify the starting block with `--head:blockNumber`"
    quit(QuitFailure)

  if conf.maxBlocks == 0:
    echo "please specify the number of problematic blocks you want to hunt with `--maxBlocks:number`"
    quit(QuitFailure)

  var
    problematicBlocks = newSeq[Uint256]()
    blockNumber = conf.head

  while true:
    echo blockNumber
    if huntProblematicBlock(blockNumber) != ValidationResult.OK:
      echo "shot down problematic block: ", blockNumber
      problematicBlocks.add blockNumber
    blockNumber = blockNumber + 1
    if problematicBlocks.len >= conf.maxBlocks:
      echo "Problematic blocks: ", problematicBlocks
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
