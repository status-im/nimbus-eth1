# The point of this file is just to give a little more type-safety
# and clarity to our use of SecureHexaryTrie, by having distinct
# types for the big trie containing all the accounts and the little
# tries containing the storage for an individual account.
#
# It's nice to have all the accesses go through "getAccountBytes"
# rather than just "get" (which is hard to search for). Plus we
# may want to put in assertions to make sure that the nodes for
# the account are all present (in stateless mode), etc.

import
  std/typetraits,
  eth/common,
  eth/trie/[db, hexary]

type
  DB = TrieDatabaseRef
  AccountsTrie* = distinct SecureHexaryTrie
  StorageTrie* = distinct SecureHexaryTrie

# I don't understand why "borrow" doesn't work here. --Adam
proc rootHash*   (trie: AccountsTrie | StorageTrie): KeccakHash      = distinctBase(trie).rootHash
proc rootHashHex*(trie: AccountsTrie | StorageTrie): string          = distinctBase(trie).rootHashHex
proc db*         (trie: AccountsTrie | StorageTrie): TrieDatabaseRef = distinctBase(trie).db
proc isPruning*  (trie: AccountsTrie | StorageTrie): bool            = distinctBase(trie).isPruning



template initAccountsTrie*(db: DB, rootHash: KeccakHash, isPruning = true): AccountsTrie =
  AccountsTrie(initSecureHexaryTrie(db, rootHash, isPruning, true))

template initAccountsTrie*(db: DB, isPruning = true): AccountsTrie =
  AccountsTrie(initSecureHexaryTrie(db, isPruning, true))

proc getAccountBytes*(trie: AccountsTrie, address: EthAddress): seq[byte] =
  SecureHexaryTrie(trie).get(address)

proc maybeGetAccountBytes*(trie: AccountsTrie, address: EthAddress): Option[seq[byte]] =
  SecureHexaryTrie(trie).maybeGet(address)

proc putAccountBytes*(trie: var AccountsTrie, address: EthAddress, value: openArray[byte]) =
  SecureHexaryTrie(trie).put(address, value)

proc delAccountBytes*(trie: var AccountsTrie, address: EthAddress) =
  SecureHexaryTrie(trie).del(address)



template initStorageTrie*(db: DB, rootHash: KeccakHash, isPruning = true): StorageTrie =
  StorageTrie(initSecureHexaryTrie(db, rootHash, isPruning, true))

template initStorageTrie*(db: DB, isPruning = true): StorageTrie =
  StorageTrie(initSecureHexaryTrie(db, isPruning, true))

template createTrieKeyFromSlot*(slot: UInt256): auto =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  slot.toByteArrayBE
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

proc getSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): seq[byte] =
  SecureHexaryTrie(trie).get(slotAsKey)

proc maybeGetSlotBytes*(trie: StorageTrie, slotAsKey: openArray[byte]): Option[seq[byte]] =
  SecureHexaryTrie(trie).maybeGet(slotAsKey)

proc putSlotBytes*(trie: var StorageTrie, slotAsKey: openArray[byte], value: openArray[byte]) =
  SecureHexaryTrie(trie).put(slotAsKey, value)

proc delSlotBytes*(trie: var StorageTrie, slotAsKey: openArray[byte]) =
  SecureHexaryTrie(trie).del(slotAsKey)

proc storageTrieForAccount*(trie: AccountsTrie, account: Account, isPruning = true): StorageTrie =
  # TODO: implement `prefix-db` to solve issue #228 permanently.
  # the `prefix-db` will automatically insert account address to the
  # underlying-db key without disturb how the trie works.
  # it will create virtual container for each account.
  # see nim-eth#9
  initStorageTrie(SecureHexaryTrie(trie).db, account.storageRoot, isPruning)
