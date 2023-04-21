#[
FIXME-Adam: I feel like this and distinct_tries should either be combined or more clearly separated.

The points of these two files are:
  - Have distinct types for the two kinds of tries, because we really don't want to mix them up.
    - Have an interface with functions like getAccountBytes rather than just get. (But still just a super-thin wrapper.)
  - Have maybeGetWhatever instead of just getWhatever. (Also assertions.)
    - Notice that this makes sense at both the bytes level and the Account/UInt256 level.

]#

import
  chronicles,
  eth/[common, rlp],
  eth/trie/[hexary, db, trie_defs],
  storage_types,
  ./values_from_bytes,
  ./distinct_tries



# Useful for debugging.
const shouldDoAssertionsForMissingNodes* = false

proc ifNodesExistGetAccountBytes*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  trie.maybeGetAccountBytes(address)

proc ifNodesExistGetStorageBytesWithinAccount*(storageTrie: StorageTrie, slotAsKey: openArray[byte]): Option[seq[byte]] =
  storageTrie.maybeGetSlotBytes(slotAsKey)


proc populateDbWithNodes*(db: TrieDatabaseRef, nodes: seq[seq[byte]]) =
  error("AARDVARK: populateDbWithNodes received nodes, about to populate", nodes)   # AARDVARK not an error, I just want it to stand out
  for nodeBytes in nodes:
    let nodeHash = keccakHash(nodeBytes)
    info("AARDVARK: populateDbWithNodes about to add node", nodeHash, nodeBytes)
    db.put(nodeHash.data, nodeBytes)

# FIXME-Adam: just make the callers call populateDbWithNodes directly?
proc populateDbWithBranch*(db: TrieDatabaseRef, branch: seq[seq[byte]]) =
  for nodeBytes in branch:
    let nodeHash = keccakHash(nodeBytes)
    db.put(nodeHash.data, nodeBytes)
  
# Returns a none if there are missing nodes; if the account itself simply
# doesn't exist yet, that's fine and it returns some(newAccount()).
proc ifNodesExistGetAccount*(trie: AccountsTrie, address: EthAddress): Option[Account] =
  ifNodesExistGetAccountBytes(trie, address).map(accountFromBytes)

proc maybeGetCode*(db: TrieDatabaseRef, codeHash: Hash256): Option[seq[byte]] =
  when defined(geth):
    return db.maybeGet(codeHash.data)
  else:
    return db.maybeGet(contractHashKey(codeHash).toOpenArray)

proc maybeGetCode*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  let maybeAcc = trie.ifNodesExistGetAccount(address)
  if maybeAcc.isNone:
    none[seq[byte]]()
  else:
    maybeGetCode(SecureHexaryTrie(trie).db, maybeAcc.get.codeHash)

proc checkingForMissingNodes_getCode*(trie: AccountsTrie, address: EthAddress): seq[byte] =
  let m = maybeGetCode(trie, address)
  doAssert(m.isSome, "missing code for account at " & $(address))
  m.get

proc assertFetchedCode*(trie: AccountsTrie, address: EthAddress) =
  if shouldDoAssertionsForMissingNodes:
    let m = maybeGetCode(trie, address)
    doAssert(m.isSome, "missing code for account at " & $(address))


proc ifNodesExistGetStorageWithinAccount*(storageTrie: StorageTrie, slot: UInt256): Option[UInt256] =
  ifNodesExistGetStorageBytesWithinAccount(storageTrie, createTrieKeyFromSlot(slot)).map(slotValueFromBytes)

proc ifNodesExistGetStorage*(trie: AccountsTrie, address: EthAddress, slot: UInt256): Option[UInt256] =
  let maybeAcc = ifNodesExistGetAccount(trie, address)
  if maybeAcc.isNone:
    none[UInt256]()
  else:
    ifNodesExistGetStorageWithinAccount(storageTrieForAccount(trie, maybeAcc.get), slot)

proc hasAllNodesForAccount*(trie: AccountsTrie, address: EthAddress): bool =
  ifNodesExistGetAccountBytes(trie, address).isSome

proc hasAllNodesForCode*(trie: AccountsTrie, address: EthAddress): bool =
  maybeGetCode(trie, address).isSome

proc hasAllNodesForStorageSlot*(trie: AccountsTrie, address: EthAddress, slot: UInt256): bool =
  ifNodesExistGetStorage(trie, address, slot).isSome

proc assertFetchedStorage*(trie: AccountsTrie, address: EthAddress, slot: UInt256) =
  doAssert(hasAllNodesForStorageSlot(trie, address, slot))
