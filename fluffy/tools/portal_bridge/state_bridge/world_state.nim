# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/tables, stint, eth/[common, trie, trie/db], eth/common/[eth_types, eth_types_rlp]

type
  AccountHash* = KeccakHash
  SlotKeyHash* = KeccakHash

  WorldStateRef* = ref object
    db: TrieDatabaseRef
    accountsTrie: HexaryTrie
    storageTries: TableRef[AccountHash, HexaryTrie]
    bytecode: TableRef[AccountHash, seq[byte]]

proc init*(T: type WorldStateRef, db: TrieDatabaseRef): T =
  WorldStateRef(
    db: db,
    accountsTrie: initHexaryTrie(db, isPruning = false),
    storageTries: newTable[AccountHash, HexaryTrie](),
    bytecode: newTable[AccountHash, seq[byte]],
  )

proc getAccountKey*(address: EthAddress): AccountHash =
  keccakHash(address)

proc getStorageKey*(slotKey: UInt256): SlotKeyHash =
  keccakHash(toBytesBE(slotKey))

# accounts - lookup by account hash

proc getAccount*(
    state: WorldStateRef, accountKey: AccountHash
): Account {.raises: [RlpError].} =
  if state.accountsTrie.contains(accountKey.data):
    rlp.decode(state.accountsTrie.get(accountKey.data), Account)
  else:
    newAccount()

proc setAccount(
    state: WorldStateRef, accountKey: AccountHash, account: Account
) {.raises: [RlpError].} =
  state.accountsTrie.put(accountKey.data, rlp.encode(account))

proc setAccountBalance*(
    state: WorldStateRef, accountKey: AccountHash, balance: UInt256
) {.raises: [RlpError].} =
  var account = state.getAccount(accountKey)
  account.balance = balance
  state.setAccount(accountKey, account)

proc setAccountNonce*(
    state: WorldStateRef, accountKey: AccountHash, nonce: AccountNonce
) {.raises: [RlpError].} =
  var account = state.getAccount(accountKey)
  account.nonce = nonce
  state.setAccount(accountKey, account)

proc setAccountStorageRoot(
    state: WorldStateRef, accountKey: AccountHash, storageRoot: KeccakHash
) {.raises: [RlpError].} =
  var account = state.getAccount(accountKey)
  account.storageRoot = storageRoot
  state.setAccount(accountKey, account)

proc setAccountCodeHash(
    state: WorldStateRef, accountKey: AccountHash, codeHash: KeccakHash
) {.raises: [RlpError].} =
  var account = state.getAccount(accountKey)
  account.codeHash = codeHash
  state.setAccount(accountKey, account)

proc deleteAccount*(
    state: WorldStateRef, accountKey: AccountHash
) {.raises: [RlpError].} =
  # TODO: review delete when updating db backend
  state.accountsTrie.del(accountKey.data)
  state.storageTries.del(accountKey)
  state.bytecode.del(accountKey)

# storage - lookup by account hash + slot hash

proc getStorage*(
    state: WorldStateRef, accountKey: AccountHash, storageKey: SlotKeyHash
): UInt256 {.raises: [RlpError].} =
  if not state.storageTries.contains(accountKey):
    return 0.u256

  let storageTrie = state.storageTries.getOrDefault(accountKey)
  if not storageTrie.contains(storageKey.data):
    return 0.u256

  rlp.decode(storageTrie.get(storageKey.data), UInt256)

proc deleteStorage*(
    state: WorldStateRef, accountKey: AccountHash, storageKey: SlotKeyHash
) {.raises: [RlpError].} =
  if not state.storageTries.contains(accountKey):
    return

  var storageTrie = state.storageTries.getOrDefault(accountKey)
  storageTrie.del(storageKey.data)

proc setStorage*(
    state: WorldStateRef,
    accountKey: AccountHash,
    storageKey: SlotKeyHash,
    value: UInt256,
) {.raises: [RlpError].} =
  if value == 0.u256:
    state.deleteStorage(accountKey, storageKey)
    return

  if not state.storageTries.contains(accountKey):
    state.storageTries[accountKey] = initHexaryTrie(state.db)

  var storageTrie = state.storageTries.getOrDefault(accountKey)
  storageTrie.put(storageKey.data, rlp.encode(value))

  state.setAccountStorageRoot(accountKey, storageTrie.rootHash())

# bytecode - lookup by account hash

proc getCode*(state: WorldStateRef, accountKey: AccountHash): seq[byte] =
  state.bytecode.getOrDefault(accountKey, @[])

proc setCode*(
    state: WorldStateRef, accountKey: AccountHash, code: seq[byte]
) {.raises: [RlpError].} =
  state.bytecode[accountKey] = code
  state.setAccountCodeHash(accountKey, keccakHash(code))

# TODO:
# apply genesis state
# apply state update
