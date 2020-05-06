import
  randutils, random, unittest,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs],
  faststreams/input_stream, nimcrypto/sysrand,
  ../stateless/[witness_from_tree, tree_from_witness],
  ../nimbus/db/storage_types, ./witness_types, ./multi_keys

type
   DB = TrieDatabaseRef

   StorageKeys = tuple[storageRoot: Hash256, keys: MultikeysRef]

   AccountDef = object
    storageKeys: MultiKeysRef
    account: Account
    codeTouched: bool

proc randU256(): UInt256 =
  var bytes: array[32, byte]
  discard randomBytes(bytes[0].addr, sizeof(result))
  result = UInt256.fromBytesBE(bytes)

proc randStorageSlot(): StorageSlot =
  discard randomBytes(result[0].addr, sizeof(result))

proc randNonce(): AccountNonce =
  discard randomBytes(result.addr, sizeof(result))

proc randCode(db: DB): Hash256 =
  if rand(0..1) == 0:
    result = blankStringHash
  else:
    let codeLen = rand(1..150)
    let code = randList(byte, rng(0, 255), codeLen, unique = false)
    result = hexary.keccak(code)
    db.put(contractHashKey(result).toOpenArray, code)

proc randStorage(db: DB): StorageKeys =
  if rand(0..1) == 0:
    result = (emptyRlpHash, MultikeysRef(nil))
  else:
    var trie = initSecureHexaryTrie(db)
    let numPairs = rand(1..10)
    var keys = newSeq[StorageSlot](numPairs)

    for i in 0..<numPairs:
      keys[i] = randStorageSlot()
      trie.put(keys[i], rlp.encode(randU256()))

    if rand(0..1) == 0:
      result = (trie.rootHash, MultikeysRef(nil))
    else:
      var m = newMultikeys(keys)
      result = (trie.rootHash, m)

proc randAccount(db: DB): AccountDef =
  result.account.nonce = randNonce()
  result.account.balance = randU256()
  let z = randStorage(db)
  result.account.codeHash = randCode(db)
  result.account.storageRoot = z.storageRoot
  result.storageKeys = z.keys
  result.codeTouched = rand(0..1) == 0

proc randAddress(): EthAddress =
  discard randomBytes(result.addr, sizeof(result))

proc runTest(numPairs: int, testStatusIMPL: var TestStatus, addInvalidKeys: static[bool] = false) =
  var memDB = newMemoryDB()
  var trie = initSecureHexaryTrie(memDB)
  var addrs = newSeq[AccountKey](numPairs)
  var accs = newSeq[Account](numPairs)

  for i in 0..<numPairs:
    let acc  = randAccount(memDB)
    addrs[i] = (randAddress(), acc.codeTouched, acc.storageKeys)
    accs[i]  = acc.account
    trie.put(addrs[i].address, rlp.encode(accs[i]))

  when addInvalidKeys:
    # invalidAddress should not end up in block witness
    let invalidAddress = randAddress()
    addrs.add((invalidAddress, false, MultikeysRef(nil)))

  var mkeys = newMultiKeys(addrs)
  let rootHash = trie.rootHash

  var wb = initWitnessBuilder(memDB, rootHash, {wfEIP170})
  var witness = wb.buildWitness(mkeys)
  var db = newMemoryDB()
  when defined(useInputStream):
    var input = memoryInput(witness)
    var tb = initTreeBuilder(input, db, {wfEIP170})
  else:
    var tb = initTreeBuilder(witness, db, {wfEIP170})
  let root = tb.buildTree()
  check root.data == rootHash.data

  let newTrie = initSecureHexaryTrie(tb.getDB(), root)
  for i in 0..<numPairs:
    let recordFound = newTrie.get(addrs[i].address)
    if recordFound.len > 0:
      let acc = rlp.decode(recordFound, Account)
      check acc == accs[i]
    else:
      debugEcho "BUG IN TREE BUILDER ", i
      check false

  when addInvalidKeys:
    for kd in mkeys.keys:
      if kd.address == invalidAddress:
        check kd.visited == false
      else:
        check kd.visited == true
  else:
    for kd in mkeys.keys:
      check kd.visited == true

proc witnessKeysMain() =
  suite "random keys block witness roundtrip test":
    randomize()

    test "random multiple keys":
      for i in 0..<100:
        runTest(rand(1..30), testStatusIMPL)

    test "there is no short node":
      let acc = newAccount()
      let rlpBytes = rlp.encode(acc)
      check rlpBytes.len > 32

    test "invalid address ignored":
      runTest(rand(1..30), testStatusIMPL, addInvalidKeys = true)

when isMainModule:
  witnessKeysMain()
