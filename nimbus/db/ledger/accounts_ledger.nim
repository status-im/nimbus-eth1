# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

## Re-write of `accounts_cache.nim` using new database API.
##
## Many objects and names are kept as in the original ``accounts_cache.nim` so
## that a diff against the original file gives useful results (e.g. using
## the graphical diff tool `meld`.)

import
  std/[tables, hashes, sets],
  chronicles,
  eth/[common, rlp],
  results,
  ../../../stateless/multi_keys,
  "../.."/[constants, errors, utils/utils],
  ../access_list as ac_access_list,
  ".."/[core_db, storage_types, transient_storage],
  ./distinct_ledgers

const
  debugAccountsLedgerRef = false

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
    account: CoreDbAccount
    flags: AccountFlags
    code: seq[byte]
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]

  WitnessData* = object
    storageKeys*: HashSet[UInt256]
    codeTouched*: bool

  AccountsLedgerRef* = ref object
    ledger: AccountLedger
    savePoint: LedgerSavePoint
    witnessCache: Table[EthAddress, WitnessData]
    isDirty: bool
    ripemdSpecial: bool

  ReadOnlyStateDB* = distinct AccountsLedgerRef

  TransactionState = enum
    Pending
    Committed
    RolledBack

  LedgerSavePoint* = ref object
    parentSavepoint: LedgerSavePoint
    cache: Table[EthAddress, RefAccount]
    selfDestruct: HashSet[EthAddress]
    logEntries: seq[Log]
    accessList: ac_access_list.AccessList
    transientStorage: TransientStorage
    state: TransactionState
    when debugAccountsLedgerRef:
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

when debugAccountsLedgerRef:
  import
    stew/byteutils

  proc inspectSavePoint(name: string, x: LedgerSavePoint) =
    debugEcho "*** ", name, ": ", x.depth, " ***"
    var sp = x
    while sp != nil:
      for address, acc in sp.cache:
        debugEcho address.toHex, " ", acc.flags
      sp = sp.parentSavepoint

proc beginSavepoint*(ac: AccountsLedgerRef): LedgerSavePoint {.gcsafe.}

# FIXME-Adam: this is only necessary because of my sanity checks on the latest rootHash;
# take this out once those are gone.
proc rawTrie*(ac: AccountsLedgerRef): AccountLedger = ac.ledger

proc db(ac: AccountsLedgerRef): CoreDbRef = ac.ledger.db
proc kvt(ac: AccountsLedgerRef): CoreDbKvtRef = ac.db.kvt

func newCoreDbAccount: CoreDbAccount =
  CoreDbAccount(
    nonce:      emptyAcc.nonce,
    balance:    emptyAcc.balance,
    codeHash:   emptyAcc.codeHash,
    storageVid: CoreDbVidRef(nil))

template noRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert info & ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""

# The AccountsLedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[AccountsLedgerRef], db: CoreDbRef,
           root: KeccakHash, pruneTrie = true): AccountsLedgerRef =
  new result
  result.ledger = AccountLedger.init(db, root, pruneTrie)
  result.witnessCache = initTable[EthAddress, WitnessData]()
  discard result.beginSavepoint

proc init*(x: typedesc[AccountsLedgerRef], db: CoreDbRef, pruneTrie = true): AccountsLedgerRef =
  init(x, db, EMPTY_ROOT_HASH, pruneTrie)

proc rootHash*(ac: AccountsLedgerRef): KeccakHash =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  ac.ledger.rootHash

proc isTopLevelClean*(ac: AccountsLedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ac.isDirty and ac.savePoint.parentSavepoint.isNil

proc beginSavepoint*(ac: AccountsLedgerRef): LedgerSavePoint =
  new result
  result.cache = initTable[EthAddress, RefAccount]()
  result.accessList.init()
  result.transientStorage.init()
  result.state = Pending
  result.parentSavepoint = ac.savePoint
  ac.savePoint = result

  when debugAccountsLedgerRef:
    if not result.parentSavePoint.isNil:
      result.depth = result.parentSavePoint.depth + 1
    inspectSavePoint("snapshot", result)

proc rollback*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

  when debugAccountsLedgerRef:
    inspectSavePoint("rollback", ac.savePoint)

proc commit*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
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

  when debugAccountsLedgerRef:
    inspectSavePoint("commit", ac.savePoint)

proc dispose*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  if sp.state == Pending:
    ac.rollback(sp)

proc safeDispose*(ac: AccountsLedgerRef, sp: LedgerSavePoint) =
  if (not isNil(sp)) and (sp.state == Pending):
    ac.rollback(sp)

proc getAccount(ac: AccountsLedgerRef, address: EthAddress, shouldCreate = true): RefAccount =
  # search account from layers of cache
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavepoint

  # not found in cache, look into state trie
  let rc = ac.ledger.fetch address
  if rc.isOk:
    result = RefAccount(
      account: rc.value,
      flags: {Alive})

  elif shouldCreate:
    result = RefAccount(
      account: newCoreDbAccount(),
      flags: {Alive, IsNew})

  else:
    return # ignore, don't cache

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

proc originalStorageValue(acc: RefAccount, slot: UInt256, ac: AccountsLedgerRef): UInt256 =
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    acc.originalStorage[].withValue(slot, val) do:
      return val[]

  # Not in the original values cache - go to the DB.
  let rc = StorageLedger.init(ac.ledger, acc.account).fetch slot
  if rc.isOk and 0 < rc.value.len:
    noRlpException "originalStorageValue()":
      result = rlp.decode(rc.value, UInt256)

  acc.originalStorage[slot] = result

proc storageValue(acc: RefAccount, slot: UInt256, ac: AccountsLedgerRef): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, ac)

proc kill(acc: RefAccount) =
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.originalStorage = nil
  acc.account = newCoreDbAccount()
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

proc persistCode(acc: RefAccount, ac: AccountsLedgerRef) =
  if acc.code.len != 0:
    when defined(geth):
      ac.kvt.put(acc.account.codeHash.data, acc.code)
    else:
      ac.kvt.put(contractHashKey(acc.account.codeHash).toOpenArray, acc.code)

proc persistStorage(acc: RefAccount, ac: AccountsLedgerRef, clearCache: bool) =
  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if not clearCache and acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  var storageLedger = StorageLedger.init(ac.ledger, acc.account)

  for slot, value in acc.overlayStorage:
    if value > 0:
      let encodedValue = rlp.encode(value)
      storageLedger.merge(slot, encodedValue)
    else:
      storageLedger.delete(slot)

    let key = slot.toBytesBE.keccakHash.data.slotHashToSlotKey
    ac.kvt.put(key.toOpenArray, rlp.encode(slot))

  if not clearCache:
    # if we preserve cache, move the overlayStorage
    # to originalStorage, related to EIP2200, EIP1283
    for slot, value in acc.overlayStorage:
      if value > 0:
        acc.originalStorage[slot] = value
      else:
        acc.originalStorage.del(slot)
    acc.overlayStorage.clear()

  acc.account.storageVid = storageLedger.rootVid

proc makeDirty(ac: AccountsLedgerRef, address: EthAddress, cloneStorage = true): RefAccount =
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

proc getCodeHash*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.codeHash
  else: acc.account.codeHash

proc getBalance*(ac: AccountsLedgerRef, address: EthAddress): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.balance
  else: acc.account.balance

proc getNonce*(ac: AccountsLedgerRef, address: EthAddress): AccountNonce =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyAcc.nonce
  else: acc.account.nonce

proc getCode*(ac: AccountsLedgerRef, address: EthAddress): seq[byte] =
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

proc getCodeSize*(ac: AccountsLedgerRef, address: EthAddress): int =
  ac.getCode(address).len

proc getCommittedStorage*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.originalStorageValue(slot, ac)

proc getStorage*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.storageValue(slot, ac)

proc hasCodeOrNonce*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.account.nonce != 0 or acc.account.codeHash != EMPTY_SHA3

proc accountExists*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.exists()

proc isEmptyAccount*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  doAssert not acc.isNil
  doAssert acc.exists()
  acc.isEmpty()

proc isDeadAccount*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return true
  if not acc.exists():
    return true
  acc.isEmpty()

proc setBalance*(ac: AccountsLedgerRef, address: EthAddress, balance: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.account.balance != balance:
    ac.makeDirty(address).account.balance = balance

proc addBalance*(ac: AccountsLedgerRef, address: EthAddress, delta: UInt256) =
  # EIP161: We must check emptiness for the objects such that the account
  # clearing (0,0,0 objects) can take effect.
  if delta.isZero:
    let acc = ac.getAccount(address)
    if acc.isEmpty:
      ac.makeDirty(address).flags.incl Touched
    return
  ac.setBalance(address, ac.getBalance(address) + delta)

proc subBalance*(ac: AccountsLedgerRef, address: EthAddress, delta: UInt256) =
  if delta.isZero:
    # This zero delta early exit is important as shown in EIP-4788.
    # If the account is created, it will change the state.
    # But early exit will prevent the account creation.
    # In this case, the SYSTEM_ADDRESS
    return
  ac.setBalance(address, ac.getBalance(address) - delta)

proc setNonce*(ac: AccountsLedgerRef, address: EthAddress, nonce: AccountNonce) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  if acc.account.nonce != nonce:
    ac.makeDirty(address).account.nonce = nonce

proc incNonce*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: AccountsLedgerRef, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let codeHash = keccakHash(code)
  if acc.account.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.account.codeHash = codeHash
    acc.code = code
    acc.flags.incl CodeChanged

proc setStorage*(ac: AccountsLedgerRef, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let oldValue = acc.storageValue(slot, ac)
  if oldValue != value:
    var acc = ac.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ac: AccountsLedgerRef, address: EthAddress) =
  # a.k.a createStateObject. If there is an existing account with
  # the given address, it is overwritten.

  let acc = ac.getAccount(address)
  acc.flags.incl {Alive, NewlyCreated}
  let accHash = acc.account.storageVid.hash(update=true).valueOr: return
  if accHash != EMPTY_ROOT_HASH:
    # there is no point to clone the storage since we want to remove it
    let acc = ac.makeDirty(address, cloneStorage = false)
    acc.account.storageVid = CoreDbVidRef(nil)
    if acc.originalStorage.isNil.not:
      # also clear originalStorage cache, otherwise
      # both getStorage and getCommittedStorage will
      # return wrong value
      acc.originalStorage.clear()

proc deleteAccount*(ac: AccountsLedgerRef, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  let acc = ac.getAccount(address)
  acc.kill()

proc selfDestruct*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setBalance(address, 0.u256)
  ac.savePoint.selfDestruct.incl address

proc selfDestruct6780*(ac: AccountsLedgerRef, address: EthAddress) =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return

  if NewlyCreated in acc.flags:
    ac.selfDestruct(address)

proc selfDestructLen*(ac: AccountsLedgerRef): int =
  ac.savePoint.selfDestruct.len

proc addLogEntry*(ac: AccountsLedgerRef, log: Log) =
  ac.savePoint.logEntries.add log

proc logEntries*(ac: AccountsLedgerRef): seq[Log] =
  ac.savePoint.logEntries

proc getAndClearLogEntries*(ac: AccountsLedgerRef): seq[Log] =
  result = ac.savePoint.logEntries
  ac.savePoint.logEntries.setLen(0)

proc ripemdSpecial*(ac: AccountsLedgerRef) =
  ac.ripemdSpecial = true

proc deleteEmptyAccount(ac: AccountsLedgerRef, address: EthAddress) =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  if not acc.isEmpty:
    return
  if not acc.exists:
    return
  acc.kill()

proc clearEmptyAccounts(ac: AccountsLedgerRef) =
  for address, acc in ac.savePoint.cache:
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      acc.kill()

  # https://github.com/ethereum/EIPs/issues/716
  if ac.ripemdSpecial:
    ac.deleteEmptyAccount(RIPEMD_ADDR)
    ac.ripemdSpecial = false

proc persist*(ac: AccountsLedgerRef,
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
        acc.persistCode(ac)
      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(ac, clearCache)
      ac.ledger.merge(address, acc.account)
    of Remove:
      ac.ledger.delete address
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

iterator addresses*(ac: AccountsLedgerRef): EthAddress =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, _ in ac.savePoint.cache:
    yield address

iterator accounts*(ac: AccountsLedgerRef): Account =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for _, account in ac.savePoint.cache:
    yield account.account.recast(update=true).value

iterator pairs*(ac: AccountsLedgerRef): (EthAddress, Account) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, account in ac.savePoint.cache:
    yield (address, account.account.recast(update=true).value)

iterator storage*(ac: AccountsLedgerRef, address: EthAddress): (UInt256, UInt256) {.gcsafe, raises: [CoreDbApiError].} =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    noRlpException "storage()":
      for slotHash, value in ac.ledger.storage acc.account:
        if slotHash.len == 0: continue
        let keyData = ac.kvt.get(slotHashToSlotKey(slotHash).toOpenArray)
        if keyData.len == 0: continue
        yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))

iterator cachedStorage*(ac: AccountsLedgerRef, address: EthAddress): (UInt256, UInt256) =
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    if not acc.originalStorage.isNil:
      for k, v in acc.originalStorage:
        yield (k, v)

proc getStorageRoot*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if acc.isNil: EMPTY_ROOT_HASH
  else: acc.account.storageVid.hash(update=true).valueOr: EMPTY_ROOT_HASH

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

proc collectWitnessData*(ac: AccountsLedgerRef) =
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

proc makeMultiKeys*(ac: AccountsLedgerRef): MultikeysRef =
  # this proc is called after we done executing a block
  new result
  for k, v in ac.witnessCache:
    result.add(k, v.codeTouched, multiKeys(v.storageKeys))
  result.sort()

proc accessList*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.savePoint.accessList.add(address)

proc accessList*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256) =
  ac.savePoint.accessList.add(address, slot)

func inAccessList*(ac: AccountsLedgerRef, address: EthAddress): bool =
  var sp = ac.savePoint
  while sp != nil:
    result = sp.accessList.contains(address)
    if result:
      return
    sp = sp.parentSavepoint

func inAccessList*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): bool =
  var sp = ac.savePoint
  while sp != nil:
    result = sp.accessList.contains(address, slot)
    if result:
      return
    sp = sp.parentSavepoint

func getTransientStorage*(ac: AccountsLedgerRef,
                          address: EthAddress, slot: UInt256): UInt256 =
  var sp = ac.savePoint
  while sp != nil:
    let (ok, res) = sp.transientStorage.getStorage(address, slot)
    if ok:
      return res
    sp = sp.parentSavepoint

proc setTransientStorage*(ac: AccountsLedgerRef,
                          address: EthAddress, slot, val: UInt256) =
  ac.savePoint.transientStorage.setStorage(address, slot, val)

proc clearTransientStorage*(ac: AccountsLedgerRef) =
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
