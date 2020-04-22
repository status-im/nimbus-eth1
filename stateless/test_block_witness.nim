import
  unittest2, os, json, strutils,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs],
  stew/byteutils, faststreams/input_stream,
  ../tests/test_helpers,
  ../nimbus/db/accounts_cache,
  ../stateless/[witness_from_tree, tree_from_witness]

type
  Tester = object
    address: seq[EthAddress]
    memDB: TrieDatabaseRef

proc isValidBranch(branch: openArray[seq[byte]], rootHash: KeccakHash, key, value: openArray[byte]): bool =
  # branch must not be empty
  doAssert(branch.len != 0)

  var db = newMemoryDB()
  for node in branch:
    doAssert(node.len != 0)
    let nodeHash = hexary.keccak(node)
    db.put(nodeHash.data, node)

  var trie = initHexaryTrie(db, rootHash)
  result = trie.get(key) == value

proc testGetBranch(tester: Tester, rootHash: KeccakHash, testStatusIMPL: var TestStatus) =
  var trie = initHexaryTrie(tester.memdb, rootHash)

  try:
    for address in tester.address:
      var wb = initWitnessBuilder(tester.memdb, rootHash)
      var witness = wb.getBranchRecurse(address)

      var db = newMemoryDB()
      var tb = initTreeBuilder(witness, db)
      var root = tb.treeNode()
      check root.data == rootHash.data
      #echo "ROOT: ", root.data.toHex
      #echo "rootHash: ", rootHash.data.toHex

      #var stackBranch = wb.getBranchStack(address)
      #check recurseBranch == stackBranch
      #
      #var branch = wb.getBranch(address)
      #let account = trie.get(address)
      #check isValidBranch(branch, trie.rootHash, address, account)
  except:
    debugEcho "MSG: ", getCurrentExceptionMsg()
    quit(1)

func parseHash256(n: JsonNode, name: string): Hash256 =
  hexToByteArray(n[name].getStr(), result.data)

proc setupStateDB(tester: var Tester, wantedState: JsonNode, stateDB: var AccountsCache): Hash256 =
  for ac, accountData in wantedState:
    let account = ethAddressFromHex(ac)
    tester.address.add(account)
    for slot, value in accountData{"storage"}:
      stateDB.setStorage(account, fromHex(UInt256, slot), fromHex(UInt256, value.getStr))

    let nonce = accountData{"nonce"}.getHexadecimalInt.AccountNonce
    let code = accountData{"code"}.getStr.safeHexToSeqByte
    let balance = UInt256.fromHex accountData{"balance"}.getStr

    stateDB.setNonce(account, nonce)
    stateDB.setCode(account, code)
    stateDB.setBalance(account, balance)

  stateDB.persist()
  result = stateDB.rootHash

proc testBlockWitness(node: JsonNode, rootHash: Hash256, testStatusIMPL: var TestStatus) =
  var
    tester = Tester(memDB: newMemoryDB())
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

suite "Block Witness":
  jsonTest("newBlockChainTests", "witnessBuilderBC", testFixtureBC)

suite "Block Witness":
  jsonTest("GeneralStateTests", "witnessBuilderGST", testFixtureGST)
