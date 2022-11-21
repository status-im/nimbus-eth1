# The point of this file is just to give a little more type-safety
# and clarity to our use of SecureHexaryTrie, by having distinct
# types for the big trie containing all the accounts and the little
# tries containing the storage for an individual account.
#
# It's nice to have all the accesses go through "getAccountBytes"
# rather than just "get" (which is hard to search for). Plus we
# may want to put in assertions to make sure that the nodes for
# the account are all present, etc.

import
  stint,
  eth/common,
  eth/rlp,
  eth/trie/[trie_defs, db, hexary],
  ./storage_types,
  ./values_from_bytes

type
  DB = TrieDatabaseRef
  AccountsTrie* = distinct SecureHexaryTrie
  StorageTrie* = distinct SecureHexaryTrie

# Useful for debugging.
const shouldDoAssertionsForMissingNodes* = false

template initAccountsTrie*(db: DB, rootHash: KeccakHash, isPruning = true): AccountsTrie =
  AccountsTrie(initSecureHexaryTrie(db, rootHash, isPruning))

proc rootHash*(trie: AccountsTrie): KeccakHash =
  SecureHexaryTrie(trie).rootHash

proc db*(trie: AccountsTrie): TrieDatabaseRef =
  SecureHexaryTrie(trie).db

proc maybeGetAccountBytes*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  SecureHexaryTrie(trie).maybeGet(address)

proc assertFetchedAccount*(trie: AccountsTrie, address: EthAddress) =
  when shouldDoAssertionsForMissingNodes:
    let m = trie.maybeGetAccountBytes(address)
    doAssert(m.isSome, "missing nodes for account at " & $(address))

proc checkingForMissingNodes_getAccountBytes*(trie: AccountsTrie, address: EthAddress): seq[byte] =
  let m = maybeGetAccountBytes(trie, address)
  if m.isSome:
    return m.get
  else:
    when shouldDoAssertionsForMissingNodes: doAssert(false, "missing nodes for account at " & $(address))
    return

proc getAccountBytes*(trie: AccountsTrie, address: EthAddress): seq[byte] =
  SecureHexaryTrie(trie).get(address)

proc putAccountBytes*(trie: var AccountsTrie, address: EthAddress, value: openArray[byte]) =
  when shouldDoAssertionsForMissingNodes: assertFetchedAccount(trie, address)
  SecureHexaryTrie(trie).put(address, value)

proc delAccountBytes*(trie: var AccountsTrie, address: EthAddress) =
  when shouldDoAssertionsForMissingNodes: assertFetchedAccount(trie, address)
  SecureHexaryTrie(trie).del(address)


template initStorageTrie*(db: DB, rootHash: KeccakHash, isPruning = true): StorageTrie =
  StorageTrie(initSecureHexaryTrie(db, rootHash, isPruning))

template createTrieKeyFromSlot*(slot: UInt256): auto =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  slot.toByteArrayBE
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

proc rootHash*(trie: StorageTrie): KeccakHash =
  SecureHexaryTrie(trie).rootHash

proc db*(trie: StorageTrie): TrieDatabaseRef =
  SecureHexaryTrie(trie).db

proc maybeGetSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): Option[seq[byte]] =
  SecureHexaryTrie(trie).maybeGet(slotAsKey)

proc assertFetchedSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]) =
  when shouldDoAssertionsForMissingNodes:
    let m = maybeGetSlotBytes(trie, slotAsKey)
    doAssert(m.isSome, "missing nodes for slot at " & $(slotAsKey))

proc checkingForMissingNodes_getSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): seq[byte] =
  let m = maybeGetSlotBytes(trie, slotAsKey)
  if m.isSome:
    return m.get
  else:
    when shouldDoAssertionsForMissingNodes: doAssert(false, "missing nodes for slot at " & $(slotAsKey))
    return

proc getSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): seq[byte] =
  SecureHexaryTrie(trie).get(slotAsKey)

proc putSlotBytes*(trie: var StorageTrie, slotAsKey: openArray[byte], value: openArray[byte]) =
  when shouldDoAssertionsForMissingNodes: assertFetchedSlotBytes(trie, slotAsKey)
  SecureHexaryTrie(trie).put(slotAsKey, value)

proc delSlotBytes*(trie: var StorageTrie, slotAsKey: openArray[byte]) =
  when shouldDoAssertionsForMissingNodes: assertFetchedSlotBytes(trie, slotAsKey)
  SecureHexaryTrie(trie).del(slotAsKey)


proc storageTrieForAccount*(trie: AccountsTrie, account: Account, isPruning = true): StorageTrie =
  # TODO: implement `prefix-db` to solve issue #228 permanently.
  # the `prefix-db` will automatically insert account address to the
  # underlying-db key without disturb how the trie works.
  # it will create virtual container for each account.
  # see nim-eth#9
  initStorageTrie(SecureHexaryTrie(trie).db, account.storageRoot, isPruning)



# FIXME-Adam: put this iterator in the hexary.nim code (nim-eth repo)?
iterator pairs*(trie: SecureHexaryTrie): (seq[byte], seq[byte]) =
  for k, v in HexaryTrie(trie):
    yield (k, v)

iterator pairsOfAccountHashAndAccountBytes*(trie: AccountsTrie): (seq[byte], seq[byte]) =
  for k, v in SecureHexaryTrie(trie):
    yield (k, v)

iterator pairsOfSlotHashAndValueBytes*(trie: StorageTrie): (seq[byte], seq[byte]) =
  for k, v in SecureHexaryTrie(trie):
    yield (k, v)

iterator storagePairs*(trie: StorageTrie): (UInt256, UInt256) =
  for slotHash, slotBytes in pairsOfSlotHashAndValueBytes(trie):
    if slotHash.len == 0:
      continue # not sure this is a good idea
    let keyData = trie.db.get(slotHashToSlotKey(slotHash).toOpenArray)
    if keyData.len == 0:
      continue # not sure this is a good idea
    yield (rlp.decode(keyData, UInt256), rlp.decode(slotBytes, UInt256))

proc storageSlots*(trie: StorageTrie): seq[UInt256] =
  for k, v in trie.storagePairs:
    result.add(k)





proc getCode*(db: TrieDatabaseRef, codeHash: Hash256): seq[byte] =
  when defined(geth):
    return db.get(codeHash.data)
  else:
    return db.get(contractHashKey(codeHash).toOpenArray)

proc getCode*(trie: AccountsTrie, address: EthAddress): seq[byte] =
  let accBytes = getAccountBytes(trie, address)
  let acc = accountFromBytes(accBytes)
  getCode(SecureHexaryTrie(trie).db, acc.codeHash)

proc putCode*(db: TrieDatabaseRef, codeHash: Hash256, code: seq[byte]) =
  when defined(geth):
    db.put(codeHash.data, code)
  else:
    db.put(contractHashKey(codeHash).toOpenArray, code)

proc putCode*(trie: AccountsTrie, codeHash: Hash256, code: seq[byte]) =
  putCode(SecureHexaryTrie(trie).db, codeHash, code)



proc ifNodesExistGetAccountBytes*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  trie.maybeGetAccountBytes(address)

proc ifNodesExistGetStorageBytesWithinAccount*(storageTrie: StorageTrie, slotAsKey: openArray[byte]): Option[seq[byte]] =
  storageTrie.maybeGetSlotBytes(slotAsKey)
