import
  randutils, random, parseopt, strutils, os,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs],
  nimcrypto/sysrand, ../stateless/[json_from_tree],
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

proc randStorage(db: DB, numSlots: int): StorageKeys =
  if rand(0..1) == 0 or numSlots == 0:
    result = (emptyRlpHash, MultikeysRef(nil))
  else:
    var trie = initSecureHexaryTrie(db)
    var keys = newSeq[StorageSlot](numSlots)

    for i in 0..<numSlots:
      keys[i] = randStorageSlot()
      trie.put(keys[i], rlp.encode(randU256()))

    if rand(0..1) == 0:
      result = (trie.rootHash, MultikeysRef(nil))
    else:
      var m = newMultikeys(keys)
      result = (trie.rootHash, m)

proc randAccount(db: DB, numSlots: int): AccountDef =
  result.account.nonce = randNonce()
  result.account.balance = randU256()
  let z = randStorage(db, numSlots)
  result.account.codeHash = randCode(db)
  result.account.storageRoot = z.storageRoot
  result.storageKeys = z.keys
  result.codeTouched = rand(0..1) == 0

proc randAddress(): EthAddress =
  discard randomBytes(result.addr, sizeof(result))

proc runGenerator(numPairs, numSlots: int): string =
  var memDB = newMemoryDB()
  var trie = initSecureHexaryTrie(memDB)
  var addrs = newSeq[AccountKey](numPairs)
  var accs = newSeq[Account](numPairs)

  for i in 0..<numPairs:
    let acc  = randAccount(memDB, numSlots)
    addrs[i] = (randAddress(), acc.codeTouched, acc.storageKeys)
    accs[i]  = acc.account
    trie.put(addrs[i].address, rlp.encode(accs[i]))

  var mkeys = newMultiKeys(addrs)
  let rootHash = trie.rootHash

  var wb = initWitnessBuilder(memDB, rootHash, {wfEIP170})
  result = wb.buildWitness(mkeys)

proc writeHelp() =
  echo "json_witness_gen output --pairs:val --slots:val -s:val -p:val"

proc main() =
  var filename: string
  var outputDir: string
  var numPairs = 1
  var numSlots = 1
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      filename = key
    of cmdLongOption, cmdShortOption:
      case key
      of "pairs", "p":
        numPairs = parseInt(val)
        if numPairs <= 0: numPairs = 1
      of "slots", "s":
        numSlots = parseInt(val)
        if numSlots < 0: numSlots = 0
      of "output", "o":
        outputDir = val
    of cmdEnd: assert(false) # cannot happen

  if filename == "":
    writeHelp()
    quit(0)

  randomize()
  let witness = runGenerator(numPairs, numSlots)
  let filePath = if outputDir.len > 0: outputDir / filename: else: filename
  writeFile(filePath, witness)

main()
