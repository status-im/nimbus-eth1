import
  unittest2, os, json, strutils,
  eth/[common, rlp], eth/trie/trie_defs,
  stew/byteutils,
  ../tests/[test_helpers, test_config],
  ../nimbus/db/[accounts_cache, core_db, distinct_tries], ./witness_types,
  ../stateless/[witness_from_tree, tree_from_witness],
  ./multi_keys

type
  Tester = object
    keys: MultikeysRef
    memDB: CoreDbRef

proc testGetBranch(tester: Tester, rootHash: KeccakHash, testStatusIMPL: var TestStatus) =
  var trie = initAccountsTrie(tester.memdb, rootHash)
  let flags = {wfEIP170}

  try:
    var wb = initWitnessBuilder(tester.memdb, rootHash, flags)
    var witness = wb.buildWitness(tester.keys)

    var db = newCoreDbRef(LegacyDbMemory)
    when defined(useInputStream):
      var input = memoryInput(witness)
      var tb = initTreeBuilder(input, db, flags)
    else:
      var tb = initTreeBuilder(witness, db, flags)

    var root = tb.buildTree()
    check root.data == rootHash.data

    let newTrie = initAccountsTrie(tb.getDB(), root)
    for kd in tester.keys.keys:
      let account = rlp.decode(trie.getAccountBytes(kd.address), Account)
      let recordFound = newTrie.getAccountBytes(kd.address)
      if recordFound.len > 0:
        let acc = rlp.decode(recordFound, Account)
        doAssert acc == account
      else:
        doAssert(false, "BUG IN WITNESS/TREE BUILDER")

  except ContractCodeError as e:
    debugEcho "CONTRACT CODE ERROR: ", e.msg

func parseHash256(n: JsonNode, name: string): Hash256 =
  hexToByteArray(n[name].getStr(), result.data)

proc setupStateDB(tester: var Tester, wantedState: JsonNode, stateDB: var AccountsCache): Hash256 =
  var keys = newSeqOfCap[AccountKey](wantedState.len)

  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    let slotVals = accountData{"storage"}
    var storageKeys = newSeqOfCap[StorageSlot](slotVals.len)

    for slotStr, value in slotVals:
      let slot = fromHex(UInt256, slotStr)
      storageKeys.add(slot.toBytesBE)
      stateDB.setStorage(account, slot, fromHex(UInt256, value.getStr))

    let nonce = accountData{"nonce"}.getHexadecimalInt.AccountNonce
    let code = accountData{"code"}.getStr.safeHexToSeqByte
    let balance = UInt256.fromHex accountData{"balance"}.getStr

    stateDB.setNonce(account, nonce)
    stateDB.setCode(account, code)
    stateDB.setBalance(account, balance)

    let sKeys = if storageKeys.len != 0: newMultiKeys(storageKeys) else: MultikeysRef(nil)
    let codeTouched = code.len > 0
    keys.add(AccountKey(address: account, codeTouched: codeTouched, storageKeys: sKeys))

  tester.keys = newMultiKeys(keys)
  stateDB.persist()
  result = stateDB.rootHash

proc testBlockWitness(node: JsonNode, rootHash: Hash256, testStatusIMPL: var TestStatus) =
  var
    tester = Tester(memDB: newCoreDbRef(LegacyDbMemory))
    ac = AccountsCache.init(tester.memDB, emptyRlpHash, true)

  let root = tester.setupStateDB(node, ac)
  if rootHash != emptyRlpHash:
    check root == rootHash

  tester.testGetBranch(root, testStatusIMPL)

proc testFixtureBC(node: JsonNode, testStatusIMPL: var TestStatus) =
  for fixtureName, fixture in node:
    let rootHash = parseHash256(fixture["genesisBlockHeader"], "stateRoot")
    fixture["pre"].testBlockWitness(rootHash, testStatusIMPL)

proc testFixtureGST(node: JsonNode, testStatusIMPL: var TestStatus) =
  var fixture: JsonNode

  for fixtureName, child in node:
    fixture = child
    break

  fixture["pre"].testBlockWitness(emptyRlpHash, testStatusIMPL)

proc blockWitnessMain*(debugMode = false) =
  const
    legacyGSTFolder = "eth_tests" / "LegacyTests" / "Constantinople" / "GeneralStateTests"
    newGSTFolder = "eth_tests" / "GeneralStateTests"
    legacyBCFolder = "eth_tests" / "LegacyTests" / "Constantinople" / "BlockchainTests"
    newBCFolder = "eth_tests" / "BlockchainTests"

  if paramCount() == 0 or not debugMode:
    # run all test fixtures
    suite "Block Witness":
      jsonTest(newBCFolder, "witnessBuilderBC", testFixtureBC)
    suite "Block Witness":
      jsonTest(newGSTFolder, "witnessBuilderGST", testFixtureGST)
  else:
    # execute single test in debug mode
    let config = getConfiguration()
    if config.testSubject.len == 0:
      echo "missing test subject"
      quit(QuitFailure)

    let folder = if config.legacy: legacyGSTFolder else: newGSTFolder
    let path = "tests" / "fixtures" / folder
    let n = json.parseFile(path / config.testSubject)
    var testStatusIMPL: TestStatus
    testFixtureGST(n, testStatusIMPL)

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
  blockWitnessMain(true)
