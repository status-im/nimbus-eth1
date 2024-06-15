# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

## Re-write of legacy `accounts_cache.nim` using new database API.
##
## Notable changes are:
##
##  * `AccountRef`
##    + renamed from `RefAccount`
##    + the `statement` entry is sort of a superset of an `Account` object
##      - contains an `EthAddress` field
##      - the storage root hash is generalised as a `CoreDbTrieRef` object
##
##  * `AccountsLedgerRef`
##    + renamed from `AccountsCache`
##

import
  std/[tables, hashes, sets],
  chronicles,
  eth/[common, rlp],
  results,
  ../../stateless/multi_keys,
  "../.."/[constants, utils/utils],
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

  AccountRef = ref object
    statement: CoreDbAccount
    flags: AccountFlags
    code: seq[byte]
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]

  WitnessData* = object
    storageKeys*: HashSet[UInt256]
    codeTouched*: bool

  AccountsLedgerRef* = ref object
    ledger: AccountLedger
    kvt: CoreDxKvtRef
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
    cache: Table[EthAddress, AccountRef]
    dirty: Table[EthAddress, AccountRef]
    selfDestruct: HashSet[EthAddress]
    logEntries: seq[Log]
    accessList: ac_access_list.AccessList
    transientStorage: TransientStorage
    state: TransactionState
    when debugAccountsLedgerRef:
      depth: int

const
  emptyEthAccount = newAccount()

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

template logTxt(info: static[string]): static[string] =
  "AccountsLedgerRef " & info

proc beginSavepoint*(ac: AccountsLedgerRef): LedgerSavePoint {.gcsafe.}

# FIXME-Adam: this is only necessary because of my sanity checks on the latest rootHash;
# take this out once those are gone.
proc rawTrie*(ac: AccountsLedgerRef): AccountLedger = ac.ledger

func newCoreDbAccount(address: EthAddress): CoreDbAccount =
  CoreDbAccount(
    address:  address,
    nonce:    emptyEthAccount.nonce,
    balance:  emptyEthAccount.balance,
    codeHash: emptyEthAccount.codeHash,
    storage:  CoreDbColRef(nil))

proc resetCoreDbAccount(ac: AccountsLedgerRef, v: var CoreDbAccount) =
  ac.ledger.freeStorage v.address
  v.nonce = emptyEthAccount.nonce
  v.balance = emptyEthAccount.balance
  v.codeHash = emptyEthAccount.codeHash
  v.storage = nil

template noRlpException(info: static[string]; code: untyped) =
  try:
    code
  except RlpError as e:
    raiseAssert info & ", name=\"" & $e.name & "\", msg=\"" & e.msg & "\""

# The AccountsLedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[AccountsLedgerRef], db: CoreDbRef,
           root: KeccakHash): AccountsLedgerRef =
  new result
  result.ledger = AccountLedger.init(db, root)
  result.kvt = db.newKvt() # save manually in `persist()`
  result.witnessCache = Table[EthAddress, WitnessData]()
  discard result.beginSavepoint

proc init*(x: typedesc[AccountsLedgerRef], db: CoreDbRef): AccountsLedgerRef =
  init(x, db, EMPTY_ROOT_HASH)

# Renamed `rootHash()` => `state()`
proc state*(ac: AccountsLedgerRef): KeccakHash =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  ac.ledger.state

proc isTopLevelClean*(ac: AccountsLedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ac.isDirty and ac.savePoint.parentSavepoint.isNil

proc beginSavepoint*(ac: AccountsLedgerRef): LedgerSavePoint =
  new result
  result.cache = Table[EthAddress, AccountRef]()
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

  for k, v in sp.dirty:
    sp.parentSavepoint.dirty[k] = v

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

proc getAccount(
    ac: AccountsLedgerRef;
    address: EthAddress;
    shouldCreate = true;
      ): AccountRef =

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
    result = AccountRef(
      statement: rc.value,
      flags: {Alive})
  elif shouldCreate:
    result = AccountRef(
      statement: address.newCoreDbAccount(),
      flags: {Alive, IsNew})
  else:
    return # ignore, don't cache

  # cache the account
  ac.savePoint.cache[address] = result
  ac.savePoint.dirty[address] = result

proc clone(acc: AccountRef, cloneStorage: bool): AccountRef =
  result = AccountRef(
    statement: acc.statement,
    flags:     acc.flags,
    code:      acc.code)

  if cloneStorage:
    result.originalStorage = acc.originalStorage
    # it's ok to clone a table this way
    result.overlayStorage = acc.overlayStorage

proc isEmpty(acc: AccountRef): bool =
  acc.statement.nonce == 0 and
    acc.statement.balance.isZero and
    acc.statement.codeHash == EMPTY_CODE_HASH

template exists(acc: AccountRef): bool =
  Alive in acc.flags

proc originalStorageValue(
    acc: AccountRef;
    slot: UInt256;
    ac: AccountsLedgerRef;
      ): UInt256 =
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    acc.originalStorage[].withValue(slot, val) do:
      return val[]

  # Not in the original values cache - go to the DB.
  let rc = StorageLedger.init(ac.ledger, acc.statement).fetch slot
  if rc.isOk and 0 < rc.value.len:
    noRlpException "originalStorageValue()":
      result = rlp.decode(rc.value, UInt256)

  acc.originalStorage[slot] = result

proc storageValue(
    acc: AccountRef;
    slot: UInt256;
    ac: AccountsLedgerRef;
      ): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, ac)

proc kill(ac: AccountsLedgerRef, acc: AccountRef) =
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.originalStorage = nil
  ac.resetCoreDbAccount acc.statement
  acc.code.reset()

type
  PersistMode = enum
    DoNothing
    Update
    Remove

proc persistMode(acc: AccountRef): PersistMode =
  result = DoNothing
  if Alive in acc.flags:
    if IsNew in acc.flags or Dirty in acc.flags:
      result = Update
  else:
    if IsNew notin acc.flags:
      result = Remove

proc persistCode(acc: AccountRef, ac: AccountsLedgerRef) =
  if acc.code.len != 0:
    let rc = ac.kvt.put(
      contractHashKey(acc.statement.codeHash).toOpenArray, acc.code)
    if rc.isErr:
      warn logTxt "persistCode()",
       codeHash=acc.statement.codeHash, error=($$rc.error)

proc persistStorage(acc: AccountRef, ac: AccountsLedgerRef) =
  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  # Make sure that there is an account address row on the database. This is
  # needed for saving the account-linked storage column on the Aristo database.
  if acc.statement.storage.isNil:
    ac.ledger.merge(acc.statement)
  var storageLedger = StorageLedger.init(ac.ledger, acc.statement)

  # Save `overlayStorage[]` on database
  for slot, value in acc.overlayStorage:
    if value > 0:
      let encodedValue = rlp.encode(value)
      storageLedger.merge(slot, encodedValue)
    else:
      storageLedger.delete(slot)
    let
      key = slot.toBytesBE.keccakHash.data.slotHashToSlotKey
      rc = ac.kvt.put(key.toOpenArray, rlp.encode(slot))
    if rc.isErr:
      warn logTxt "persistStorage()", slot, error=($$rc.error)

  # move the overlayStorage to originalStorage, related to EIP2200, EIP1283
  for slot, value in acc.overlayStorage:
    if value > 0:
      acc.originalStorage[slot] = value
    else:
      acc.originalStorage.del(slot)
  acc.overlayStorage.clear()

  # Changing the storage trie might also change the `storage` descriptor when
  # the trie changes from empty to exixting or v.v.
  acc.statement.storage = storageLedger.getColumn()

  # No need to hold descriptors for longer than needed
  let state = acc.statement.storage.state.valueOr:
    raiseAssert "Storage column state error: " & $$error
  if state == EMPTY_ROOT_HASH:
    acc.statement.storage = CoreDbColRef(nil)


proc makeDirty(ac: AccountsLedgerRef, address: EthAddress, cloneStorage = true): AccountRef =
  ac.isDirty = true
  result = ac.getAccount(address)
  if address in ac.savePoint.cache:
    # it's already in latest savepoint
    result.flags.incl Dirty
    ac.savePoint.dirty[address] = result
    return

  # put a copy into latest savepoint
  result = result.clone(cloneStorage)
  result.flags.incl Dirty
  ac.savePoint.cache[address] = result
  ac.savePoint.dirty[address] = result

proc getCodeHash*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyEthAccount.codeHash
  else: acc.statement.codeHash

proc getBalance*(ac: AccountsLedgerRef, address: EthAddress): UInt256 =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyEthAccount.balance
  else: acc.statement.balance

proc getNonce*(ac: AccountsLedgerRef, address: EthAddress): AccountNonce =
  let acc = ac.getAccount(address, false)
  if acc.isNil: emptyEthAccount.nonce
  else: acc.statement.nonce

proc getCode(acc: AccountRef, kvt: CoreDxKvtRef): lent seq[byte] =
  if CodeLoaded notin acc.flags and CodeChanged notin acc.flags:
    if acc.statement.codeHash != EMPTY_CODE_HASH:
      var rc = kvt.get(contractHashKey(acc.statement.codeHash).toOpenArray)
      if rc.isErr:
        warn logTxt "getCode()", codeHash=acc.statement.codeHash, error=($$rc.error)
      else:
        acc.code = move(rc.value)
        acc.flags.incl CodeLoaded
  else:
    acc.flags.incl CodeLoaded # avoid hash comparisons

  acc.code

proc getCode*(ac: AccountsLedgerRef, address: EthAddress): seq[byte] =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return

  acc.getCode(ac.kvt)

proc getCodeSize*(ac: AccountsLedgerRef, address: EthAddress): int =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return

  acc.getCode(ac.kvt).len

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

proc contractCollision*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return
  acc.statement.nonce != 0 or
    acc.statement.codeHash != EMPTY_CODE_HASH or
     acc.statement.storage.stateOrVoid != EMPTY_ROOT_HASH

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
  if acc.statement.balance != balance:
    ac.makeDirty(address).statement.balance = balance

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
  if acc.statement.nonce != nonce:
    ac.makeDirty(address).statement.nonce = nonce

proc incNonce*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: AccountsLedgerRef, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address)
  acc.flags.incl {Alive}
  let codeHash = keccakHash(code)
  if acc.statement.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.statement.codeHash = codeHash
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

  let accHash = acc.statement.storage.state.valueOr: return
  if accHash != EMPTY_ROOT_HASH:
    # need to clear the storage from the database first
    let acc = ac.makeDirty(address, cloneStorage = false)
    ac.ledger.freeStorage address
    acc.statement.storage = CoreDbColRef(nil)
    # update caches
    if acc.originalStorage.isNil.not:
      # also clear originalStorage cache, otherwise
      # both getStorage and getCommittedStorage will
      # return wrong value
      acc.originalStorage.clear()

proc deleteAccount*(ac: AccountsLedgerRef, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  let acc = ac.getAccount(address)
  ac.savePoint.dirty[address] = acc
  ac.kill acc

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

  ac.savePoint.dirty[address] = acc
  ac.kill acc

proc clearEmptyAccounts(ac: AccountsLedgerRef) =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  for acc in ac.savePoint.dirty.values():
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      ac.kill acc

  # https://github.com/ethereum/EIPs/issues/716
  if ac.ripemdSpecial:
    ac.deleteEmptyAccount(RIPEMD_ADDR)
    ac.ripemdSpecial = false

proc persist*(ac: AccountsLedgerRef,
              clearEmptyAccount: bool = false) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)

  if clearEmptyAccount:
    ac.clearEmptyAccounts()

  for address in ac.savePoint.selfDestruct:
    ac.deleteAccount(address)

  for acc in ac.savePoint.dirty.values(): # This is a hotspot in block processing
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ac)
      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(ac)
      ac.ledger.merge(acc.statement)
    of Remove:
      ac.ledger.delete acc.statement.address
      ac.savePoint.cache.del acc.statement.address
    of DoNothing:
      # dead man tell no tales
      # remove touched dead account from cache
      if Alive notin acc.flags:
        ac.savePoint.cache.del acc.statement.address

    acc.flags = acc.flags - resetFlags
  ac.savePoint.dirty.clear()

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
    yield account.statement.recast().value

iterator pairs*(ac: AccountsLedgerRef): (EthAddress, Account) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  for address, account in ac.savePoint.cache:
    yield (address, account.statement.recast().value)

iterator storage*(ac: AccountsLedgerRef, address: EthAddress): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    noRlpException "storage()":
      for slotHash, value in ac.ledger.storage acc.statement:
        if slotHash.len == 0: continue
        let rc = ac.kvt.get(slotHashToSlotKey(slotHash).toOpenArray)
        if rc.isErr:
          warn logTxt "storage()", slotHash, error=($$rc.error)
        else:
          yield (rlp.decode(rc.value, UInt256), rlp.decode(value, UInt256))

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
  else: acc.statement.storage.state.valueOr: EMPTY_ROOT_HASH

proc update(wd: var WitnessData, acc: AccountRef) =
  # once the code is touched make sure it doesn't get reset back to false in another update
  if not wd.codeTouched:
    wd.codeTouched = CodeChanged in acc.flags or CodeLoaded in acc.flags

  if not acc.originalStorage.isNil:
    for k, v in acc.originalStorage:
      if v.isZero: continue
      wd.storageKeys.incl k

  for k, v in acc.overlayStorage:
    wd.storageKeys.incl k

proc witnessData(acc: AccountRef): WitnessData =
  result.storageKeys = HashSet[UInt256]()
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

func multiKeys(slots: HashSet[UInt256]): MultiKeysRef =
  if slots.len == 0: return
  new result
  for x in slots:
    result.add x.toBytesBE
  result.sort()

proc makeMultiKeys*(ac: AccountsLedgerRef): MultiKeysRef =
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

func getAccessList*(ac: AccountsLedgerRef): common.AccessList =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  ac.savePoint.accessList.getAccessList()

proc getEthAccount*(ac: AccountsLedgerRef, address: EthAddress): Account =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    return emptyEthAccount

  ## Convert to legacy object, will throw an assert if that fails
  let rc = acc.statement.recast()
  if rc.isErr:
    raiseAssert "getAccount(): cannot convert account: " & $$rc.error
  rc.value

proc state*(db: ReadOnlyStateDB): KeccakHash {.borrow.}
proc getCodeHash*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getStorageRoot*(db: ReadOnlyStateDB, address: EthAddress): Hash256 {.borrow.}
proc getBalance*(db: ReadOnlyStateDB, address: EthAddress): UInt256 {.borrow.}
proc getStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
proc getNonce*(db: ReadOnlyStateDB, address: EthAddress): AccountNonce {.borrow.}
proc getCode*(db: ReadOnlyStateDB, address: EthAddress): seq[byte] {.borrow.}
proc getCodeSize*(db: ReadOnlyStateDB, address: EthAddress): int {.borrow.}
proc contractCollision*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc accountExists*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isDeadAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc isEmptyAccount*(db: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
proc getCommittedStorage*(db: ReadOnlyStateDB, address: EthAddress, slot: UInt256): UInt256 {.borrow.}
func inAccessList*(ac: ReadOnlyStateDB, address: EthAddress): bool {.borrow.}
func inAccessList*(ac: ReadOnlyStateDB, address: EthAddress, slot: UInt256): bool {.borrow.}
func getTransientStorage*(ac: ReadOnlyStateDB,
                          address: EthAddress, slot: UInt256): UInt256 {.borrow.}
