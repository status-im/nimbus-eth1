# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, hashes, sets],
  chronicles,
  eth/common,
  ../../../stateless/multi_keys,
  ../../constants,
  ../../utils/utils,
  ../access_list as ac_access_list,
  "../../../vendor/nim-eth-verkle/eth_verkle"/[
    math,
    tree/tree
  ],
  ../verkle/verkle_accounts,
  ".."/[core_db, verkle_distinct_tries, transient_storage]


const
  debugAccountsCache = false

## Rewrite of AccountsCache as per the Verkle Specs, Notable changes:
## 1) No storage trie, as storage is now a part of the unified Verkle Trie (EIP 6800)
## 2) Changing the format of Witness Data and Witness Cache
## 3) Changing the trie in AccountsCache to a VerkleTrie

type
  AccountFlag = enum
    Alive
    IsNew
    Dirty
    Touched
    CodeLoaded
    CodeChanged
    StorageChanged
    NewlyCreated # EIP-6780: self destruct only in same transaction

  AccountFlags = set[AccountFlag]

  RefAccount = ref object
    account: Account
    flags: AccountFlags
    code: seq[byte]
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]


  ## Needs to be replaced with the ExecutionWitness used in Verkle Trees:
  ## Format:
  ##  ExecutionWitness:
  ##    StateDiff 
  ##    VerkleProof (rootHash)
  ## 
  WitnessData* = object
    storageKeys*: HashSet[UInt256]
    codeTouched*: bool

  AccountsCache* = ref object
    trie: VerkleTrie
    savePoint: SavePoint
    witnessCache: Table[EthAddress, WitnessData]
    isDirty: bool
    ripemdSpecial: bool

  ReadOnlyStateDB* = distinct AccountsCache

  TransactionState = enum
    Pending
    Committed
    RolledBack

  SavePoint* = ref object
    parentSavepoint: SavePoint
    cache: Table[EthAddress, RefAccount]
    selfDestruct: HashSet[EthAddress]
    logEntries: seq[Log]
    accessList: ac_access_list.AccessList
    transientStorage: TransientStorage
    state: TransactionState
    when debugAccountsCache:
      depth: int

const
  emptyAcc = newAccount()

  resetFlags = {
    Dirty,
    IsNew,
    Touched,
    CodeChanged,
    StorageChanged,
    NewlyCreated
    }

when debugAccountsCache:
  import
    stew/byteutils

  proc inspectSavePoint(name: string, x: SavePoint) =
    debugEcho "*** ", name, ": ", x.depth, " ***"
    var sp = x
    while sp != nil:
      for address, acc in sp.cache:
        debugEcho address.toHex, " ", acc.flags
      sp = sp.parentSavepoint

proc beginSavePoint*(ac: AccountsCache): SavePoint {.gcsafe.}

proc rawTrie*(ac: AccountsCache): VerkleTrie {.inline.} = ac.trie

proc init*(x: typedesc[AccountsCache]): AccountsCache =
  new result
  result.trie = initVerkleTrie()
  result.witnessCache = initTable[EthAddress, WitnessData]
  discard result.beginSavePoint

proc rootHash*(ac: AccountsCache): KeccakHash =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  result.data = VerkleTrieRef(ac.trie).hashVerkleTrie()

proc isTopLevelClean*(ac: AccountsCache): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ac.isDirty and ac.savePoint.parentSavepoint.isNil

proc beginSavepoint*(ac: AccountsCache): SavePoint =
  new result
  result.cache = initTable[EthAddress, RefAccount]()
  result.accessList.init()
  result.transientStorage.init()
  result.state = Pending
  result.parentSavepoint = ac.savePoint
  ac.savePoint = result

  when debugAccountsCache:
    if not result.parentSavePoint.isNil:
      result.depth = result.parentSavePoint.depth + 1
    inspectSavePoint("snapshot", result)

proc rollback*(ac: AccountsCache, sp: SavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

  when debugAccountsCache:
    inspectSavePoint("rollback", ac.savePoint)

proc commit*(ac: AccountsCache, sp: SavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  # cannot commit most inner savepoint
  doAssert not sp.parentSavepoint.isNil

  ac.savePoint = sp.parentSavepoint
  for k, v in sp.cache:
    sp.parentSavepoint.cache[k] = v

  ac.savePoint.transientStorage.merge(sp.transientStorage)
  ac.savePoint.accessList.merge(sp.accessList)
  ac.savePoint.selfDestruct.incl sp.selfDestruct
  ac.savePoint.logEntries.add sp.logEntries
  sp.state = Committed

  when debugAccountsCache:
    inspectSavePoint("commit", ac.savePoint)

proc dispose*(ac: AccountsCache, sp: SavePoint) {.inline.} =
  if sp.state == Pending:
    ac.rollback(sp)

proc safeDispose*(ac: AccountsCache, sp: SavePoint) {.inline.} =
  if (not isNil(sp)) and (sp.state == Pending):
    ac.rollback(sp)

proc getAccount(ac: AccountsCache, address: EthAddress, shouldCreate = true): RefAccount =
  # look for account from layers of cache
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavepoint

  let account = ac.trie.getAccountBytes(address)

  # Check if the account fetched from the Verkle Trie is Empty or not
  if (not account.isEmptyVerkleAccount()):
    result = RefAccount(
      account: account,
      flags: {Alive}
    )

  else:
    if not shouldCreate:
      return
    # it's a request for new account
    result = RefAccount(
      account: newAccount(),
      flags: {Alive, IsNew}
      )
  
  # cache the account
  ac.savePoint.cache[address] = result

proc clone(acc: RefAccount, cloneStorage: bool): RefAccount =
  new(result)
  result.account = acc.account
  result.flags = acc.flags
  result.code = acc.code

  if cloneStorage:
    result.originalStorage = acc.originalStorage
    # it's ok to clone a table this way
    result.overlayStorage = acc.overlayStorage

# TODO: Verify logic
proc isEmpty(acc: RefAccount): bool =
  result = acc.account.codeHash == EMPTY_SHA3 and  # in verkle codeHash might not be be == EMPTY_CODE_HASH
    acc.account.balance.isZero and
    acc.account.nonce == 0

template exists(acc: RefAccount): bool =
  Alive in acc.flags

proc originalStorageValue(acc: RefAccount, address: EthAddress, slot: UInt256, db: VerkleTrie): UInt256 =
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    acc.originalStorage[].withValue(slot, val) do:
      return val[]

  # Not in the original values cache - go to the DB.
  var (slotAsKey, subIndex) = createTrieKeyFromSlot(slot.toBytesBE())
  discard subIndex

  let foundRecord = db.getSlotBytes(address, slotAsKey.toBytesBE())
  result = UInt256.fromBytesBE(foundRecord)

  acc.originalStorage[slot] = result

proc storageValue(acc: RefAccount, address: EthAddress, slot: UInt256, db: VerkleTrie): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(address, slot, db)

proc kill(acc: RefAccount) =
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.originalStorage = nil
  acc.account = newAccount()
  acc.code = default(seq[byte])

type
  PersistMode = enum
    DoNothing
    Update
    Remove

proc persistMode(acc: RefAccount): PersistMode =
  result = DoNothing
  if Alive in acc.flags:
    if IsNew in acc.flags or Dirty in acc.flags:
      result = Update
  else:
    if IsNew notin acc.flags:
      result = Remove

proc persistCode(acc: RefAccount, address: EthAddress, db: VerkleTrie) =
  if acc.code.len != 0:
    when defined(geth):
      VerkleTrieRef(db).updateContractCode(address, acc.account.codeHash, acc.code)
    else:
      VerkleTrieRef(db).updateContractCode(address, acc.account.codeHash, acc.code)

proc persistStorage(acc: RefAccount, address: EthAddress, db: VerkleTrie, clearCache: bool) =
  if acc.overlayStorage.len == 0:
    return

  if not clearCache and acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  for slot, value in acc.overlayStorage:
    var (slotAsKey, subIndex) = createTrieKeyFromSlot(slot.toBytesBE())
    discard subIndex

    if value > 0:
      var slotBytes = slotAsKey.toBytesBE()
      var valueToBytes = value.toBytesBE()
      db.putSlotBytes(address, slotBytes, valueToBytes)

    else:
      ## No delete operation for now in Kaustinen
      discard

  if not clearCache:
    # if we preserve cache, move the overlayStorage
    # to originalStorage, related to EIP2200, EIP1283
    for slot, value in acc.overlayStorage:
      if value > 0:
        acc.originalStorage[slot] = value
      else:
        acc.originalStorage.del(slot)
    acc.overlayStorage.clear()

proc getBalance*(ac: AccountsCache, address: EthAddress): UInt256 {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.balance
  else: acc.account.balance

proc getNonce*(ac: AccountsCache, address: EthAddress): AccountNonce {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.nonce
  else: acc.account.nonce

proc getCodeSize*(ac: AccountsCache, address: EthAddress): int {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: 0
  else: acc.code.len

proc getCodeHash*(ac: AccountsCache, address: EthAddress): Hash256 {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.codeHash
  else: acc.account.codeHash

proc makeDirty(ac: AccountsCache, address: EthAddress, cloneStorage = true): RefAccount =
  ac.isDirty = true
  result = ac.getAccount(address)
  if address in ac.savePoint.cache:
    # it's already in latest savepoint
    result.flags.incl Dirty
    return

  # put a copy into latest savepoint
  result = result.clone(cloneStorage)
  result.flags.incl Dirty
  ac.savePoint.cache[address] = result

# TODO : Verify the logic of empty hash for verkle
proc hasCodeOrNonce*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.account.nonce != 0 or acc.account.codeHash != EMPTY_SHA3  # for verkle this might not be the EMPTY_CODE_HASH

proc accountExists*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.exists()

proc isEmptyAccount*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address, false)
  doAssert not acc.isNil
  doAssert acc.exists()
  acc.isEmpty()

proc isDeadAccount*(ac: AccountsCache, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return true
  if not acc.exists():
    return true
  acc.isEmpty()

proc setBalance*(ac: AccountsCache, address: EthAddress, balance: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.account.balance != balance:
    ac.makeDirty(address).account.balance = balance

proc addBalance*(ac: AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  # EIP161: We must check emptiness for the objects such that the account
  # clearing (0,0,0 objects) can take effect.
  if delta.isZero:
    let acc = ac.getAccount(address)
    if acc.isEmpty:
      ac.makeDirty(address).flags.incl Touched
    return
  ac.setBalance(address, ac.getBalance(address) + delta)

proc subBalance*(ac: AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  if delta.isZero:
    # This zero delta early exit is important as shown in EIP-4788.
    # If the account is created, it will change the state.
    # But early exit will prevent the account creation.
    # In this case, the SYSTEM_ADDRESS
    return
  ac.setBalance(address, ac.getBalance(address) - delta)

proc setNonce*(ac: AccountsCache, address: EthAddress, nonce: AccountNonce) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.account.nonce != nonce:
    ac.makeDirty(address).account.nonce = nonce

proc incNonce*(ac: AccountsCache, address: EthAddress) {.inline.} =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setStorage*(ac: AccountsCache, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let oldValue = acc.storageValue(address, slot, ac.trie)
  if oldValue != value:
    var acc = ac.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ac: AccountsCache, address: EthAddress) =
  # a.k.a createStateObject. If there is an existing account with
  # the given address, it is overwritten.

  let acc = ac.getAccount(address)
  acc.flags.incl {Alive, NewlyCreated}
  if acc.account.storageRoot != EMPTY_ROOT_HASH:
    # there is no point to clone the storage since we want to remove it
    let acc = ac.makeDirty(address, cloneStorage = false)
    acc.account.storageRoot = EMPTY_ROOT_HASH
    if acc.originalStorage.isNil.not:
      # also clear originalStorage cache, otherwise
      # both getStorage and getCommittedStorage will
      # return wrong value
      acc.originalStorage.clear()

proc setCode*(ac: AccountsCache, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let codeHash = keccakHash(code)
  if acc.account.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.account.codeHash = codeHash
    acc.code = code
    acc.flags.incl CodeChanged

proc deleteAccount*(ac: AccountsCache, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  let acc = ac.getAccount(address)
  acc.kill()

proc selfDestruct*(ac: AccountsCache, address: EthAddress) =
  ac.setBalance(address, 0.u256)
  ac.savePoint.selfDestruct.incl address

proc selfDestruct6780*(ac: AccountsCache, address: EthAddress) =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return

  if NewlyCreated in acc.flags:
    ac.selfDestruct(address)

proc selfDestructLen*(ac: AccountsCache): int =
  ac.savePoint.selfDestruct.len

proc addLogEntry*(ac: AccountsCache, log: Log) =
  ac.savePoint.logEntries.add log

proc logEntries*(ac: AccountsCache): seq[Log] =
  ac.savePoint.logEntries

proc getAndClearLogEntries*(ac: AccountsCache): seq[Log] =
  result = ac.savePoint.logEntries
  ac.savePoint.logEntries.setLen(0)

proc ripemdSpecial*(ac: AccountsCache) =
  ac.ripemdSpecial = true

proc deleteEmptyAccount(ac: AccountsCache, address: EthAddress) =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  if not acc.isEmpty:
    return
  if not acc.exists:
    return
  acc.kill()

proc clearEmptyAccounts(ac: AccountsCache) =
  for address, acc in ac.savePoint.cache:
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      acc.kill()

  # https://github.com/ethereum/EIPs/issues/716
  if ac.ripemdSpecial:
    ac.deleteEmptyAccount(RIPEMD_ADDR)
    ac.ripemdSpecial = false


iterator addresses*(ac: AccountsCache): EthAddress =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, _ in ac.savePoint.cache:
    yield address

iterator accounts*(ac: AccountsCache): Account =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for _, account in ac.savePoint.cache:
    yield account.account

iterator pairs*(ac: AccountsCache): (EthAddress, Account) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, account in ac.savePoint.cache:
    yield (address, account.account)

# Storage iterator missing @agnxsh

iterator cachedStorage*(ac: AccountsCache, address: EthAddress): (UInt256, UInt256) =
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    if not acc.originalStorage.isNil:
      for k, v in acc.originalStorage:
        yield (k, v)

proc accessList*(ac: AccountsCache, address: EthAddress) {.inline.} =
  ac.savePoint.accessList.add(address)

proc accessList*(ac: AccountsCache, address: EthAddress, slot: UInt256) {.inline.} =
  ac.savePoint.accessList.add(address, slot)

func inAccessList*(ac: AccountsCache, address: EthAddress): bool =
  var sp = ac.savePoint
  while sp != nil:
    result = sp.accessList.contains(address)
    if result:
      return
    sp = sp.parentSavepoint

func inAccessList*(ac: AccountsCache, address: EthAddress, slot: UInt256): bool =
  var sp = ac.savePoint
  while sp != nil:
    result = sp.accessList.contains(address, slot)
    if result:
      return
    sp = sp.parentSavepoint

func getTransientStorage*(ac: AccountsCache,
                          address: EthAddress, slot: UInt256): UInt256 =
  var sp = ac.savePoint
  while sp != nil:
    let (ok, res) = sp.transientStorage.getStorage(address, slot)
    if ok:
      return res
    sp = sp.parentSavepoint

proc setTransientStorage*(ac: AccountsCache,
                          address: EthAddress, slot, val: UInt256) =
  ac.savePoint.transientStorage.setStorage(address, slot, val)

proc clearTransientStorage*(ac: AccountsCache) {.inline.} =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  ac.savePoint.transientStorage.clear()

func getAccessList*(ac: AccountsCache): common.AccessList =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  ac.savePoint.accessList.getAccessList()


proc persist*(ac: AccountsCache,
              clearEmptyAccount: bool = false,
              clearCache: bool = true) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  var cleanAccounts = initHashSet[EthAddress]()

  if clearEmptyAccount:
    ac.clearEmptyAccounts()

  for address in ac.savePoint.selfDestruct:
    ac.deleteAccount(address)

  for address, acc in ac.savePoint.cache:             
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(address, ac.trie)
      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(address, ac.trie, clearCache)
      ac.trie.putAccountBytes address, acc.account
    of Remove:
      VerkleTrieRef(ac.trie).delAccountBytes address
      if not clearCache:
        cleanAccounts.incl address
    of DoNothing:
      # dead man tell no tales
      # remove touched dead account from cache
      if not clearCache and Alive notin acc.flags:
        cleanAccounts.incl address

    acc.flags = acc.flags - resetFlags

  if clearCache:
    ac.savePoint.cache.clear()
  else:
    for x in cleanAccounts:
      ac.savePoint.cache.del x

  ac.savePoint.selfDestruct.clear()

  # EIP2929
  ac.savePoint.accessList.clear()

  ac.isDirty = false

proc getStorageRoot*(ac: AccountsCache, address: EthAddress): Hash256 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.storageRoot
  else: acc.account.storageRoot

func update(wd: var WitnessData, acc: RefAccount) =
  # once the code is touched make sure it doesn't get reset back to false in another update
  if not wd.codeTouched:
    wd.codeTouched = CodeChanged in acc.flags or CodeLoaded in acc.flags

  if not acc.originalStorage.isNil:
    for k, v in acc.originalStorage:
      if v.isZero: continue
      wd.storageKeys.incl k

  for k, v in acc.overlayStorage:
    wd.storageKeys.incl k

func witnessData(acc: RefAccount): WitnessData =
  result.storageKeys = initHashSet[UInt256]()
  update(result, acc)

proc collectWitnessData*(ac: AccountsCache) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # usually witness data is collected before we call persist()
  for address, acc in ac.savePoint.cache:
    ac.witnessCache.withValue(address, val) do:
      update(val[], acc)
    do:
      ac.witnessCache[address] = witnessData(acc)

func multiKeys(slots: HashSet[UInt256]): MultiKeysRef =
  if slots.len == 0: return
  new result
  for x in slots:
    result.add x.toBytesBE
  result.sort()

proc makeMultiKeys*(ac: AccountsCache): MultiKeysRef =
  # this proc is called after we done executing a block
  new result
  for k, v in ac.witnessCache:
    result.add(k, v.codeTouched, multiKeys(v.storageKeys))
  result.sort()