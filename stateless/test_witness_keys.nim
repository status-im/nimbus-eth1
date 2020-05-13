import
  randutils, random, unittest, stew/byteutils,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs, nibbles],
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
      debugEcho "BUG IN WITNESS/TREE BUILDER ", i
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

proc initMultiKeys(keys: openArray[string]): MultikeysRef =
  result.new
  for x in keys:
    result.keys.add KeyData(
      storageMode: false,
      hash: hexToByteArray[32](x)
    )

proc witnessKeysMain*() =
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

    test "case 1: all keys is a match":
      let keys = [
        "0abc7124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0abccc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0abca163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6bb"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 0
        mg.group.last == 2

    test "case 2: all keys is not a match":
      let keys = [
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0456a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6bb"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == false

    test "case 3: not match and match":
      let keys = [
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0abc6a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "0abc7a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 2
        mg.group.last == 3

    test "case 4: match and not match":
      let keys = [
        "0abc6a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "0abc7a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 0
        mg.group.last == 1

    test "case 5: not match, match and not match":
      let keys = [
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606",
        "0abc6a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "0abc7a163140158288775c8912aed274fb9d6a3a260e9e95e03e70ba8df30f6b",
        "01237124bce7762869be690036144c12c256bdb06ee9073ad5ecca18a47c3254",
        "0890cc5b491732f964182ce4bde5e2468318692ed446e008f621b26f8ff56606"
      ]

      let m  = initMultiKeys(keys)
      let pg = m.initGroup()
      let n  = initNibbleRange(hexToByteArray[2]("0abc"))
      let mg = m.groups(0, n, pg)
      check:
        mg.match == true
        mg.group.first == 2
        mg.group.last == 3

when isMainModule:
  witnessKeysMain()
