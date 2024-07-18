# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stint,
  eth/[common, trie, trie/db],
  eth/common/[eth_types, eth_types_rlp],
  ../../../common/common_types,
  ./database

# Account State definition

type AccountState* = ref object
  account: Account
  storageUpdates: Table[UInt256, UInt256]
  code: seq[byte]
  codeUpdated: bool

proc init(T: type AccountState, account = newAccount()): T =
  T(account: account, codeUpdated: false)

proc setBalance*(accState: var AccountState, balance: UInt256) =
  accState.account.balance = balance

proc addBalance*(accState: var AccountState, balance: UInt256) =
  accState.account.balance += balance

proc setNonce*(accState: var AccountState, nonce: AccountNonce) =
  accState.account.nonce = nonce

proc setStorage*(accState: var AccountState, slotKey: UInt256, slotValue: UInt256) =
  accState.storageUpdates[slotKey] = slotValue

proc deleteStorage*(accState: var AccountState, slotKey: UInt256) =
  # setting to zero has the effect of deleting the slot
  accState.setStorage(slotKey, 0.u256)

proc setCode*(accState: var AccountState, code: seq[byte]) =
  accState.code = code
  accState.codeUpdated = true

# World State definition

type
  AccountHash = KeccakHash
  SlotKeyHash = KeccakHash

  WorldStateRef* = ref object
    accountsTrie: HexaryTrie
    storageTries: TableRef[AccountHash, HexaryTrie]
    storageDb: TrieDatabaseRef
    bytecodeDb: TrieDatabaseRef # maps AccountHash -> seq[byte]

proc init*(T: type WorldStateRef, db: DatabaseRef): T =
  WorldStateRef(
    accountsTrie: initHexaryTrie(db.getAccountsBackend(), isPruning = false),
    storageTries: newTable[AccountHash, HexaryTrie](),
    storageDb: db.getStorageBackend(),
    bytecodeDb: db.getBytecodeBackend(),
  )

template stateRoot*(state: WorldStateRef): KeccakHash =
  state.accountsTrie.rootHash()

template toAccountKey(address: EthAddress): AccountHash =
  keccakHash(address)

template toStorageKey(slotKey: UInt256): SlotKeyHash =
  keccakHash(toBytesBE(slotKey))

proc getAccount*(state: WorldStateRef, address: EthAddress): AccountState =
  let accountKey = toAccountKey(address)

  try:
    if state.accountsTrie.contains(accountKey.data):
      let accountBytes = state.accountsTrie.get(accountKey.data)
      AccountState.init(rlp.decode(accountBytes, Account))
    else:
      AccountState.init()
  except RlpError as e:
    raiseAssert(e.msg) # should never happen unless the database is corrupted

proc setAccount*(state: WorldStateRef, address: EthAddress, accState: AccountState) =
  let accountKey = toAccountKey(address)

  try:
    if not state.storageTries.contains(accountKey):
      state.storageTries[accountKey] =
        initHexaryTrie(state.storageDb, isPruning = false)

    var storageTrie = state.storageTries.getOrDefault(accountKey)
    for k, v in accState.storageUpdates:
      if v == 0.u256:
        storageTrie.del(toStorageKey(k).data)
      else:
        storageTrie.put(toStorageKey(k).data, rlp.encode(v))

    state.storageTries[accountKey] = storageTrie

    var accountToSave = accState.account
    accountToSave.storageRoot = storageTrie.rootHash()

    if accState.codeUpdated:
      state.bytecodeDb.put(accountKey.data, accState.code)
      accountToSave.codeHash = keccakHash(accState.code)

    state.accountsTrie.put(accountKey.data, rlp.encode(accountToSave))
  except RlpError as e:
    raiseAssert(e.msg) # should never happen unless the database is corrupted

proc deleteAccount*(state: WorldStateRef, address: EthAddress) =
  let accountKey = toAccountKey(address)

  try:
    state.accountsTrie.del(accountKey.data)
    state.storageTries.del(accountKey)
    state.bytecodeDb.del(accountKey.data)
  except RlpError as e:
    raiseAssert(e.msg) # should never happen unless the database is corrupted
