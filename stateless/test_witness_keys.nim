import
  randutils, stew/byteutils, random,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs],
  faststreams/input_stream, nimcrypto/[utils, sysrand],
  ../stateless/[witness_from_tree, tree_from_witness],
  ../nimbus/db/storage_types

type
   DB = TrieDatabaseRef

proc randU256(): UInt256 =
  var bytes: array[32, byte]
  discard randomBytes(bytes[0].addr, sizeof(result))
  result = UInt256.fromBytesBE(bytes)

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

proc randStorage(db: DB): Hash256 =
  if rand(0..1) == 0:
    result = emptyRlpHash
  else:
    var trie = initSecureHexaryTrie(db)
    let numPairs = rand(1..5)

    for i in 0..<numPairs:
      # we bypass u256 key to slot conversion
      # discard randomBytes(key.addr, sizeof(key))
      trie.put(i.u256.toByteArrayBE, rlp.encode(randU256()))
    result = trie.rootHash

proc randAccount(db: DB): Account =
  result.nonce = randNonce()
  result.balance = randU256()
  result.codeHash = randCode(db)
  result.storageRoot = randStorage(db)

proc randAddress(): EthAddress =
  discard randomBytes(result.addr, sizeof(result))

proc runTest(numPairs: int) =
  var memDB = newMemoryDB()
  var trie = initSecureHexaryTrie(memDB)
  var addrs = newSeq[EthAddress](numPairs)

  for i in 0..<numPairs:
    addrs[i] = randAddress()
    let acc = randAccount(memDB)
    trie.put(addrs[i], rlp.encode(acc))

  let rootHash = trie.rootHash

  var wb = initWitnessBuilder(memDB, rootHash)
  var witness = wb.buildWitness(addrs[0])
  var db = newMemoryDB()
  when defined(useInputStream):
    var input = memoryInput(witness)
    var tb = initTreeBuilder(input, db)
  else:
    var tb = initTreeBuilder(witness, db)
  var root = tb.treeNode()
  debugEcho "root: ", root.data.toHex
  debugEcho "rootHash: ", rootHash.data.toHex
  doAssert root.data == rootHash.data

proc main() =
  randomize()

  for i in 0..<30:
    runTest(rand(1..30))

main()
