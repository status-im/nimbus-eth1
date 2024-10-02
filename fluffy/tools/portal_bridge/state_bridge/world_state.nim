# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stint,
  eth/[common, trie, trie/db, trie/trie_defs],
  eth/common/[eth_types, eth_types_rlp],
  ../../../common/[common_types, common_utils],
  ./database

# Account State definition

type AccountState* = ref object
  account: Account
  storageUpdates: Table[UInt256, UInt256]
  code: seq[byte]
  codeUpdated: bool

proc init(T: type AccountState, account = newAccount()): T =
  T(account: account, codeUpdated: false)

template getBalance*(accState: AccountState): UInt256 =
  accState.account.balance

template getNonce*(accState: AccountState): AccountNonce  =
  accState.account.nonce

template setBalance*(accState: var AccountState, bal: UInt256) =
  accState.account.balance = bal

template addBalance*(accState: var AccountState, bal: UInt256) =
  accState.account.balance += bal

template setNonce*(accState: var AccountState, nce: AccountNonce) =
  accState.account.nonce = nce

template setStorage*(
    accState: var AccountState, slotKey: UInt256, slotValue: UInt256
) =
  accState.storageUpdates[slotKey] = slotValue

template deleteStorage*(accState: var AccountState, slotKey: UInt256) =
  # setting to zero has the effect of deleting the slot
  accState.setStorage(slotKey, 0.u256)

template setCode*(accState: var AccountState, bytecode: seq[byte]) =
  accState.code = bytecode
  accState.codeUpdated = true

# World State definition

type
  AddressHash* = KeccakHash
  SlotKeyHash* = KeccakHash

  WorldStateRef* = ref object
    db: DatabaseRef
    accountsTrie: HexaryTrie
    storageTries: TableRef[AddressHash, HexaryTrie]
    storageDb: TrieDatabaseRef
    bytecodeDb: TrieDatabaseRef # maps AddressHash -> seq[byte]

proc init*(
    T: type WorldStateRef, db: DatabaseRef, accountsTrieRoot: KeccakHash = emptyRlpHash
): T =
  WorldStateRef(
    db: db,
    accountsTrie:
      if accountsTrieRoot == emptyRlpHash:
        initHexaryTrie(db.getAccountsBackend(), isPruning = false)
      else:
        initHexaryTrie(db.getAccountsBackend(), accountsTrieRoot, isPruning = false),
    storageTries: newTable[AddressHash, HexaryTrie](),
    storageDb: db.getStorageBackend(),
    bytecodeDb: db.getBytecodeBackend()
  )

template stateRoot*(state: WorldStateRef): KeccakHash =
  state.accountsTrie.rootHash()

template toAccountKey*(address: EthAddress): AddressHash =
  keccakHash(address)

template toStorageKey*(slotKey: UInt256): SlotKeyHash =
  keccakHash(toBytesBE(slotKey))

proc getAccount(state: WorldStateRef, accountKey: AddressHash): AccountState =
  try:
    if state.accountsTrie.contains(accountKey.data):
      let accountBytes = state.accountsTrie.get(accountKey.data)
      AccountState.init(rlp.decode(accountBytes, Account))
    else:
      AccountState.init()
  except RlpError as e:
    raiseAssert(e.msg) # should never happen unless the database is corrupted

template getAccount*(state: WorldStateRef, address: EthAddress): AccountState =
  state.getAccount(toAccountKey(address))

proc setAccount*(state: WorldStateRef, address: EthAddress, accState: AccountState) =
  let accountKey = toAccountKey(address)

  try:
    if not state.storageTries.contains(accountKey):
      if accState.account.storageRoot == EMPTY_ROOT_HASH:
        state.storageTries[accountKey] =
          initHexaryTrie(state.storageDb, isPruning = false)
      else:
        state.storageTries[accountKey] = initHexaryTrie(
          state.storageDb, accState.account.storageRoot, isPruning = false
        )

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

# Returns the account proofs for all the updated accounts from the last transaction
iterator updatedAccountProofs*(state: WorldStateRef): (AddressHash, seq[seq[byte]]) =
  let trie = initHexaryTrie(
    state.db.getAccountsUpdatedCache(), state.stateRoot(), isPruning = false
  )

  try:
    for key in trie.keys():
      if key.len() == 0:
        continue # skip the empty node created on initialization
      yield (KeccakHash.fromBytes(key), trie.getBranch(key))
  except RlpError as e:
    raiseAssert(e.msg) # should never happen unless the database is corrupted

# Returns the storage proofs for the updated slots for the given account from the last transaction
iterator updatedStorageProofs*(
    state: WorldStateRef, accountKey: AddressHash
): (SlotKeyHash, seq[seq[byte]]) =
  let accState = state.getAccount(accountKey)

  let trie = initHexaryTrie(
    state.db.getStorageUpdatedCache(), accState.account.storageRoot, isPruning = false
  )

  try:
    for key in trie.keys():
      if key.len() == 0:
        continue # skip the empty node created on initialization
      yield (KeccakHash.fromBytes(key), trie.getBranch(key))
  except RlpError as e:
    raiseAssert(e.msg) # should never happen unless the database is corrupted

template getUpdatedBytecode*(
    state: WorldStateRef, accountKey: AddressHash
): seq[byte] =
  state.db.getBytecodeUpdatedCache().get(accountKey.data)

# Slow: Only used for testing
proc verifyProofs*(
    state: WorldStateRef, preStateRoot: KeccakHash, expectedStateRoot: KeccakHash
) =
  try:
    let trie =
      initHexaryTrie(state.db.getAccountsBackend(), preStateRoot, isPruning = false)

    var memDb = newMemoryDB()
    for k, v in trie.replicate():
      memDb.put(k, v)

    for accountKey, proof in state.updatedAccountProofs():
      doAssert isValidBranch(
        proof,
        expectedStateRoot,
        @(accountKey.data),
        rlpFromBytes(proof[^1]).listElem(1).toBytes(), # pull the value out of the proof
      )
      for p in proof:
        memDb.put(keccakHash(p).data, p)

    let memTrie = initHexaryTrie(memDb, expectedStateRoot, isPruning = false)
    doAssert(memTrie.rootHash() == expectedStateRoot)

    for accountKey, proof in state.updatedAccountProofs():
      let
        accountBytes = memTrie.get(accountKey.data)
        account = rlp.decode(accountBytes, Account)
      doAssert(accountBytes.len() > 0)
      doAssert(accountBytes == rlpFromBytes(proof[^1]).listElem(1).toBytes())
        # pull the value out of the proof

      for slotHash, sProof in state.updatedStorageProofs(accountKey):
        doAssert isValidBranch(
          sProof,
          account.storageRoot,
          @(slotHash.data),
          rlpFromBytes(sProof[^1]).listElem(1).toBytes(),
            # pull the value out of the proof
        )

      let updatedCode = state.getUpdatedBytecode(accountKey)
      if updatedCode.len() > 0:
        doAssert(account.codeHash == keccakHash(updatedCode))
  except RlpError as e:
    raiseAssert(e.msg) # Should never happen
