import
  unittest2,
  stint,
  sets, tables,
  eth/[common, rlp],
  eth/trie/[hexary, db, trie_defs],
  ../nimbus/db/[distinct_tries, incomplete_db]

type
  Branch = seq[seq[byte]]
  ProofBasedDbTestSetup = tuple[trie: SecureHexaryTrie, branches: Table[string, Branch]]

template createTrieKeyFromSlotHex(slotHex: string): auto =
  createTrieKeyFromSlot(UInt256.fromHex(slotHex))

proc slotValueFromRecord(r: seq[byte]): UInt256 =
  if r.len > 0:
    rlp.decode(r, UInt256)
  else:
    UInt256.zero()

proc getStorageHex(trie: SecureHexaryTrie, slotHex: string): string =
  let slotAsKey = createTrieKeyFromSlotHex(slotHex)
  let foundRecord = trie.get(slotAsKey)
  let value = slotValueFromRecord(foundRecord)
  return "0x" & value.toHex

proc maybeGetStorageHex(trie: SecureHexaryTrie, slotHex: string): Option[string] =
  let slotAsKey = createTrieKeyFromSlotHex(slotHex)
  let maybeFoundRecord = trie.maybeGet(slotAsKey)
  if maybeFoundRecord.isSome:
    return some("0x" & slotValueFromRecord(maybeFoundRecord.get).toHex)
  else:
    return none[string]()

proc setStorageHex(trie: var SecureHexaryTrie, slotHex: string, valueHex: string) =
  trie.put(createTrieKeyFromSlotHex(slotHex), rlp.encode(UInt256.fromHex(valueHex)))

proc createTrieFromSlots(slotValues: Table[string, string]): SecureHexaryTrie =
  var trie = initSecureHexaryTrie(newMemoryDB(), false)
  for slotHex, valueHex in slotValues:
    setStorageHex(trie, slotHex, valueHex)
  return trie

proc getBranches(trie: SecureHexaryTrie, slotHexes: HashSet[string]): Table[string, Branch] =
  for slotHex in slotHexes:
    result[slotHex] = getBranch(trie, createTrieKeyFromSlotHex(slotHex))

# FIXME-Adam: What's the idiomatic Nim way to pass around the keys of a Table?
proc keySet[A, B](t: Table[A, B]): HashSet[A] =
  for k in t.keys:
    result.incl(k)

proc createTestSetupFromSlots(slotValues: Table[string, string]): ProofBasedDbTestSetup =
  let trie = createTrieFromSlots(slotValues)
  let branches = getBranches(trie, keySet(slotValues))
  return (trie, branches)

proc createTrieFromBranches(rootHash: KeccakHash, branches: seq[Branch]): SecureHexaryTrie =
  var trie = initSecureHexaryTrie(newMemoryDB(), rootHash, false)
  for branch in branches:
    populateDbWithBranch(trie.db, branch)
  return trie

proc dbMadeFromProofsMain*() =
  suite "making DB from proofs tests":
    test "can modify a DB and it gets the correct root hash even though it does not have all the values":
      var (trie1, branches) = createTestSetupFromSlots(toTable([("0x1", "0x11"), ("0x2", "0x22")]))
      var trie2 = createTrieFromBranches(trie1.rootHash, @[branches["0x1"]])
      doAssert(getStorageHex(trie1, "0x1") == "0x11")
      doAssert(getStorageHex(trie1, "0x2") == "0x22")
      doAssert(maybeGetStorageHex(trie2, "0x1") == some("0x11"))
      # trie2 is missing the value at key 0x2, but still has the same root hash
      # as trie1.
      doAssert(maybeGetStorageHex(trie2, "0x2") == none[string]())
      doAssert(trie1.rootHash == trie2.rootHash)
      # If we make the same modifications to both, they'll still have equal
      # root hashes.
      setStorageHex(trie1, "0x3", "0x33")
      setStorageHex(trie2, "0x3", "0x33")
      doAssert(maybeGetStorageHex(trie1, "0x3") == some("0x33"))
      doAssert(maybeGetStorageHex(trie2, "0x3") == some("0x33"))
      doAssert(trie1.rootHash == trie2.rootHash)
      # Even after trie2 has been modified, we can still fill in the nodes
      # for the missing key/value pair, and then the value will be available.
      populateDbWithBranch(trie2.db, branches["0x2"])
      doAssert(maybeGetStorageHex(trie2, "0x2") == some("0x22"))

when isMainModule:
  dbMadeFromProofsMain()
