import
  json, downloader, stint, strutils, byteutils, parser, nimcrypto,
  chronicles, ../nimbus/tracer, eth_trie/[defs, db], ../nimbus/vm_state,
  ../nimbus/db/[db_chain, state_db], ../nimbus/p2p/executor, premixcore,
  eth_common, configuration

const
  emptyCodeHash = blankStringHash
  emptyStorageHash = emptyRlpHash

proc store(memoryDB: TrieDatabaseRef, branch: JsonNode) =
  for p in branch:
    let rlp = hexToSeqByte(p.getStr)
    let hash = keccak256.digest(rlp)
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
      let code = hexToSeqByte(codeStr.getStr).toRange
      accountDB.setCode(address, code)
  result = memoryDB

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

  let
    vmState = newBaseVMState(parentBlock.header, chainDB)
    validationResult = processBlock(chainDB, parentBlock.header, thisBlock.header, thisBlock.body, vmState)

  if validationResult != ValidationResult.OK:
    dumpDebuggingMetaData(chainDB, thisBlock.header, thisBlock.body, vmState.receipts, false)

  result = validationResult

proc main() =
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
