# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

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
  eth/[common, trie/db],
  "."/[core_db, distinct_tries, storage_types, values_from_bytes]



# Useful for debugging.
const shouldDoAssertionsForMissingNodes* = false

proc ifNodesExistGetAccountBytes*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  trie.maybeGetAccountBytes(address)

proc ifNodesExistGetStorageBytesWithinAccount*(storageTrie: StorageTrie, slotAsKey: openArray[byte]): Option[seq[byte]] =
  storageTrie.maybeGetSlotBytes(slotAsKey)


proc populateDbWithNodes*(db: CoreDbRef, nodes: seq[seq[byte]]) =
  error("GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG AARDVARK: populateDbWithNodes received nodes, about to populate", nodes)   # AARDVARK not an error, I just want it to stand out
  for nodeBytes in nodes:
    let nodeHash = keccakHash(nodeBytes)
    info("AARDVARK: populateDbWithNodes about to add node", nodeHash, nodeBytes)
    db.kvt.put(nodeHash.data, nodeBytes)

# AARDVARK: just make the callers call populateDbWithNodes directly?
proc populateDbWithBranch*(db: CoreDbRef, branch: seq[seq[byte]]) =
  for nodeBytes in branch:
    let nodeHash = keccakHash(nodeBytes)
    db.kvt.put(nodeHash.data, nodeBytes)

# Returns a none if there are missing nodes; if the account itself simply
# doesn't exist yet, that's fine and it returns some(newAccount()).
proc ifNodesExistGetAccount*(trie: AccountsTrie, address: EthAddress): Option[Account] =
  ifNodesExistGetAccountBytes(trie, address).map(accountFromBytes)

proc maybeGetCode*(db: CoreDbRef, codeHash: Hash256): Option[seq[byte]] =
  when defined(geth):
    if db.isLegacy:
      db.newKvt.backend.toLegacy.maybeGet(codeHash.data)
    else:
      db.kvt.get(codeHash.data)
  else:
    if db.isLegacy:
      db.newKvt.backend.toLegacy.maybeGet(contractHashKey(codeHash).toOpenArray)
    else:
      some(db.kvt.get(contractHashKey(codeHash).toOpenArray))

proc maybeGetCode*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  let maybeAcc = trie.ifNodesExistGetAccount(address)
  if maybeAcc.isNone:
    none[seq[byte]]()
  else:
    maybeGetCode(trie.db, maybeAcc.get.codeHash)

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
