# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[tables, hashes, sets],
  eth/[common, rlp],
  ../../stateless/multi_keys,
  ../constants,
  ../utils/utils,
  ./access_list as ac_access_list,
  "."/[core_db, distinct_tries, storage_types, transient_storage]

const
  debugAccountsCache = false

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

  WitnessData* = object
    storageKeys*: HashSet[UInt256]
    codeTouched*: bool

  AccountsCache* = ref object
    trie: AccountsTrie
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

  ripemdAddr* = block:
    proc initAddress(x: int): EthAddress {.compileTime.} =
      result[19] = x.byte
    initAddress(3)

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

proc beginSavepoint*(ac: var AccountsCache): SavePoint {.gcsafe.}

# FIXME-Adam: this is only necessary because of my sanity checks on the latest rootHash;
# take this out once those are gone.
proc rawTrie*(ac: AccountsCache): AccountsTrie = ac.trie

func db(ac: AccountsCache): CoreDbRef = ac.trie.db
func kvt(ac: AccountsCache): CoreDbKvtObj = ac.db.kvt

# The AccountsCache is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[AccountsCache], db: CoreDbRef,
           root: KeccakHash, pruneTrie = true): AccountsCache =
  new result
  result.trie = initAccountsTrie(db, root, pruneTrie)
  result.witnessCache = initTable[EthAddress, WitnessData]()
  discard result.beginSavepoint

proc init*(x: typedesc[AccountsCache], db: CoreDbRef, pruneTrie = true): AccountsCache =
  init(x, db, EMPTY_ROOT_HASH, pruneTrie)

proc rootHash*(ac: AccountsCache): KeccakHash =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  ac.trie.rootHash

proc isTopLevelClean*(ac: AccountsCache): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ac.isDirty and ac.savePoint.parentSavepoint.isNil

proc beginSavepoint*(ac: var AccountsCache): SavePoint =
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

proc rollback*(ac: var AccountsCache, sp: SavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

  when debugAccountsCache:
    inspectSavePoint("rollback", ac.savePoint)

proc commit*(ac: var AccountsCache, sp: SavePoint) =
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

proc dispose*(ac: var AccountsCache, sp: SavePoint) {.inline.} =
  if sp.state == Pending:
    ac.rollback(sp)

proc safeDispose*(ac: var AccountsCache, sp: SavePoint) {.inline.} =
  if (not isNil(sp)) and (sp.state == Pending):
    ac.rollback(sp)

proc getAccount(ac: AccountsCache, address: EthAddress, shouldCreate = true): RefAccount =
  # search account from layers of cache
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavepoint

  # not found in cache, look into state trie
  let recordFound =
    try:
      ac.trie.getAccountBytes(address)
    except RlpError:
      raiseAssert("No RlpError should occur on trie access for an address")
  if recordFound.len > 0:
    # we found it
    try:
      result = RefAccount(
        account: rlp.decode(recordFound, Account),
        flags: {Alive}
        )
    except RlpError:
      raiseAssert("No RlpError should occur on decoding account from trie")
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

proc isEmpty(acc: RefAccount): bool =
  result = acc.account.codeHash == EMPTY_SHA3 and
    acc.account.balance.isZero and
    acc.account.nonce == 0

template exists(acc: RefAccount): bool =
  Alive in acc.flags

template createTrieKeyFromSlot(slot: UInt256): auto =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  slot.toBytesBE
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

template getStorageTrie(db: CoreDbRef, acc: RefAccount): auto =
  # TODO: implement `prefix-db` to solve issue #228 permanently.
  # the `prefix-db` will automatically insert account address to the
  # underlying-db key without disturb how the trie works.
  # it will create virtual container for each account.
  # see nim-eth#9
  initStorageTrie(db, acc.account.storageRoot, false)

proc originalStorageValue(acc: RefAccount, slot: UInt256, db: CoreDbRef): UInt256 =
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    acc.originalStorage[].withValue(slot, val) do:
      return val[]

  # Not in the original values cache - go to the DB.
  let
    slotAsKey = createTrieKeyFromSlot slot
    storageTrie = getStorageTrie(db, acc)
    foundRecord = storageTrie.getSlotBytes(slotAsKey)

  result = if foundRecord.len > 0:
            rlp.decode(foundRecord, UInt256)
          else:
            UInt256.zero()

  acc.originalStorage[slot] = result

proc storageValue(acc: RefAccount, slot: UInt256, db: CoreDbRef): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, db)

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

proc persistCode(acc: RefAccount, db: CoreDbRef) =
  if acc.code.len != 0:
    when defined(geth):
      db.kvt.put(acc.account.codeHash.data, acc.code)
    else:
      db.kvt.put(contractHashKey(acc.account.codeHash).toOpenArray, acc.code)

proc persistStorage(acc: RefAccount, db: CoreDbRef, clearCache: bool) =
  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if not clearCache and acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  db.compensateLegacySetup()
  var storageTrie = getStorageTrie(db, acc)

  for slot, value in acc.overlayStorage:
    let slotAsKey = createTrieKeyFromSlot slot

    if value > 0:
      let encodedValue = rlp.encode(value)
      storageTrie.putSlotBytes(slotAsKey, encodedValue)
    else:
      storageTrie.delSlotBytes(slotAsKey)

    # TODO: this can be disabled if we do not perform
    #       accounts tracing
    # map slothash back to slot value
    # see iterator storage below
    # slotHash can be obtained from storageTrie.putSlotBytes?
    let slotHash = keccakHash(slotAsKey)
    db.kvt.put(slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot))

  if not clearCache:
    # if we preserve cache, move the overlayStorage
    # to originalStorage, related to EIP2200, EIP1283
    for slot, value in acc.overlayStorage:
      if value > 0:
        acc.originalStorage[slot] = value
      else:
        acc.originalStorage.del(slot)
    acc.overlayStorage.clear()

  acc.account.storageRoot = storageTrie.rootHash

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

proc getCodeHash*(ac: AccountsCache, address: EthAddress): Hash256 {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.codeHash
  else: acc.account.codeHash

proc getBalance*(ac: AccountsCache, address: EthAddress): UInt256 {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.balance
  else: acc.account.balance

proc getNonce*(ac: AccountsCache, address: EthAddress): AccountNonce {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.nonce
  else: acc.account.nonce

proc getCode*(ac: AccountsCache, address: EthAddress): seq[byte] =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return

  if CodeLoaded in acc.flags or CodeChanged in acc.flags:
    result = acc.code
  else:
    when defined(geth):
      let data = ac.kvt.get(acc.account.codeHash.data)
    else:
      let data = ac.kvt.get(contractHashKey(acc.account.codeHash).toOpenArray)

    acc.code = data
    acc.flags.incl CodeLoaded
    result = acc.code

proc getCodeSize*(ac: AccountsCache, address: EthAddress): int {.inline.} =
  ac.getCode(address).len

proc getCommittedStorage*(ac: AccountsCache, address: EthAddress, slot: UInt256): UInt256 {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.originalStorageValue(slot, ac.db)

proc getStorage*(ac: AccountsCache, address: EthAddress, slot: UInt256): UInt256 {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.storageValue(slot, ac.db)

proc hasCodeOrNonce*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.account.nonce != 0 or acc.account.codeHash != EMPTY_SHA3

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
  if delta == 0.u256:
    let acc = ac.getAccount(address)
    if acc.isEmpty:
      ac.makeDirty(address).flags.incl Touched
    return
  ac.setBalance(address, ac.getBalance(address) + delta)

proc subBalance*(ac: AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  ac.setBalance(address, ac.getBalance(address) - delta)

proc setNonce*(ac: AccountsCache, address: EthAddress, nonce: AccountNonce) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.account.nonce != nonce:
    ac.makeDirty(address).account.nonce = nonce

proc incNonce*(ac: AccountsCache, address: EthAddress) {.inline.} =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: AccountsCache, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let codeHash = keccakHash(code)
  if acc.account.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.account.codeHash = codeHash
    acc.code = code
    acc.flags.incl CodeChanged

proc setStorage*(ac: AccountsCache, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let oldValue = acc.storageValue(slot, ac.db)
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

proc deleteAccount*(ac: AccountsCache, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  let acc = ac.getAccount(address)
  acc.kill()

proc selfDestruct*(ac: AccountsCache, address: EthAddress) =
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
    ac.deleteEmptyAccount(ripemdAddr)
    ac.ripemdSpecial = false

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
        acc.persistCode(ac.db)
      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(ac.db, clearCache)
      ac.trie.putAccountBytes address, rlp.encode(acc.account)
    of Remove:
      ac.trie.delAccountBytes address
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

iterator storage*(ac: AccountsCache, address: EthAddress): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    let storageRoot = acc.account.storageRoot
    let trie = ac.db.mptPrune storageRoot

    for slotHash, value in trie:
      if slotHash.len == 0: continue
      let keyData = ac.kvt.get(slotHashToSlotKey(slotHash).toOpenArray)
      if keyData.len == 0: continue
      yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))

iterator cachedStorage*(ac: AccountsCache, address: EthAddress): (UInt256, UInt256) =
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    if not acc.originalStorage.isNil:
      for k, v in acc.originalStorage:
        yield (k, v)

proc getStorageRoot*(ac: AccountsCache, address: EthAddress): Hash256 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.storageRoot
  else: acc.account.storageRoot

func update(wd: var WitnessData, acc: RefAccount) =
  wd.codeTouched = CodeChanged in acc.flags

  if not acc.originalStorage.isNil:
    for k, v in acc.originalStorage:
      if v.isZero: continue
      wd.storageKeys.incl k

  for k, v in acc.overlayStorage:
    if v.isZero and k notin wd.storageKeys:
      continue
    if v.isZero and k in wd.storageKeys:
      wd.storageKeys.excl k
      continue
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

func multiKeys(slots: HashSet[UInt256]): MultikeysRef =
  if slots.len == 0: return
  new result
  for x in slots:
    result.add x.toBytesBE
  result.sort()

proc makeMultiKeys*(ac: AccountsCache): MultikeysRef =
  # this proc is called after we done executing a block
  new result
  for k, v in ac.witnessCache:
    result.add(k, v.codeTouched, multiKeys(v.storageKeys))
  result.sort()

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

proc rootHash*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, address: EthAddress): UInt256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, address: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, address: EthAddress): seq[byte] {.borrow.}
proc getCodeSize*(db: ReadOnlyStateDB, address: EthAddress): int {.borrow.}
proc hasCodeOrNonce*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc getCommittedStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
func inAccessList*(ac: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
func inAccessList*(ac: ReadOnlyStateDB, address: EthAddress, slot: UInt256): bool {.borrow.}
func getTransientStorage*(ac: ReadOnlyStateDB,
                          address: EthAddress, slot: UInt256): UInt256 {.borrow.}
