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

## Re-write of `accounts_cache.nim` using new database API.
##
## Many objects and names are kept as in the original ``accounts_cache.nim` so
## that a diff against the original file gives useful results (e.g. using
## the graphical diff tool `meld`.)
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

# ------------------------ debugging --------------------------

import
  stew/byteutils
var
  noisy* = false
const
  triggerPfxSet = {0xa1,0x5d}

proc selfNoisy(w: bool): bool {.discardable.} =
  result = noisy
  noisy = w

proc setNoisy*(w: bool): bool {.discardable.} =
  w.selfNoisy

template exec*(noisy = false; code: untyped): untyped =
  block:
    let save = selfNoisy noisy
    defer: selfNoisy save
    code

# ------------------------ debugging --------------------------
    
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
    stoTrie:  CoreDbTrieRef(nil))

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
  result.kvt = db.newKvt() # save manually in `persist()`
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
  result.cache = initTable[EthAddress, AccountRef]()
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

proc getAccount(
    ac: AccountsLedgerRef;
    address: EthAddress;
    info: string;
    shouldCreate = true;
      ): AccountRef =
  # search account from layers of cache
  let trigger = address[0] in triggerPfxSet
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      if noisy and trigger: echo "*** getAccount (1) cache",
        "\n    address=", address.toHex,
        "\n    nonce=", result.statement.nonce,
        "\n    balance=", result.statement.balance,
        "\n    codeHash=", result.statement.codeHash.data.toHex,
        "\n    stoTrie=", $$result.statement.stoTrie,
        "\n    info=", info,
        ""
      return
    sp = sp.parentSavepoint

  # not found in cache, look into state trie
  let rc = ac.ledger.fetch address
  if rc.isOk:
    result = AccountRef(
      statement: rc.value,
      flags: {Alive})
    if noisy and trigger: echo "*** getAccount (2) fetch",
      "\n    address=", address.toHex,
      "\n    nonce=", result.statement.nonce,
      "\n    balance=", result.statement.balance,
      "\n    codeHash=", result.statement.codeHash.data.toHex,
      "\n    stoTrie=", $$result.statement.stoTrie,
      "\n    info=", info,
      ""
  elif shouldCreate:
    result = AccountRef(
      statement: address.newCoreDbAccount(),
      flags: {Alive, IsNew})
    if noisy and trigger: echo "*** getAccount (3) new",
      "\n    address=", address.toHex,
      "\n    nonce=", result.statement.nonce,
      "\n    balance=", result.statement.balance,
      "\n    codeHash=", result.statement.codeHash.data.toHex,
      "\n    stoTrie=", $$result.statement.stoTrie,
      "\n    info=", info,
      ""
  else:
    if noisy and trigger: echo "*** getAccount (4) none",
      "\n    address=", address.toHex,
      "\n    info=", info,
      ""
    return # ignore, don't cache

  # cache the account
  ac.savePoint.cache[address] = result


proc clone(acc: AccountRef, cloneStorage: bool): AccountRef =
  if noisy: echo "*** clone (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  result = AccountRef(
    statement: acc.statement,
    flags:     acc.flags,
    code:      acc.code)

  if cloneStorage:
    result.originalStorage = acc.originalStorage
    # it's ok to clone a table this way
    result.overlayStorage = acc.overlayStorage

proc isEmpty(acc: AccountRef): bool =
  result = acc.statement.codeHash == EMPTY_SHA3 and
    acc.statement.balance.isZero and
    acc.statement.nonce == 0

template exists(acc: AccountRef): bool =
  Alive in acc.flags

proc originalStorageValue(
    acc: AccountRef;
    slot: UInt256;
    ac: AccountsLedgerRef;
      ): UInt256 =
  if noisy: echo "*** originalStorageValue (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
    if noisy: echo "*** originalStorageValue (2)",
      "\n    stoTrie=", $$acc.statement.stoTrie,
      ""
  else:
    acc.originalStorage[].withValue(slot, val) do:
      if noisy: echo "*** originalStorageValue (3)",
        "\n    stoTrie=", $$acc.statement.stoTrie,
        ""
      return val[]

  # Not in the original values cache - go to the DB.
  let rc = StorageLedger.init(ac.ledger, acc.statement).fetch slot
  if rc.isOk and 0 < rc.value.len:
    noRlpException "originalStorageValue()":
      if noisy: echo "*** originalStorageValue (4)",
        "\n    stoTrie=", $$acc.statement.stoTrie,
        ""
      result = rlp.decode(rc.value, UInt256)

  if noisy: echo "*** originalStorageValue (9)",
    "\n    stoTrie=", $$acc.statement.stoTrie
  acc.originalStorage[slot] = result

proc storageValue(
    acc: AccountRef;
    slot: UInt256;
    ac: AccountsLedgerRef;
      ): UInt256 =
  if noisy: echo "*** storageValue (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, ac)

proc kill(acc: AccountRef, address: EthAddress) =
  if noisy: echo "*** kill (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.originalStorage = nil
  acc.statement = address.newCoreDbAccount()
  acc.code = default(seq[byte])

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
    when defined(geth):
      let rc = ac.kvt.put(
        acc.statement.codeHash.data, acc.code)
    else:
      let rc = ac.kvt.put(
        contractHashKey(acc.statement.codeHash).toOpenArray, acc.code)
    if rc.isErr:
      warn logTxt "persistCode()",
       codeHash=acc.statement.codeHash, error=($$rc.error)

proc persistStorage(acc: AccountRef, ac: AccountsLedgerRef, clearCache: bool) =
  if noisy: echo "*** persistStorage (1)",
    " clearCache=", clearCache,
    "\n    address=", acc.statement.address.toHex,
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  let slSave = distinct_ledgers.noisy
  distinct_ledgers.noisy = noisy
  defer: distinct_ledgers.noisy = slSave

  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if not clearCache and acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  ac.ledger.db.compensateLegacySetup()

  # Make sure that there is an account on the database. This is needed for
  # saving the storage trie on the Aristo database. The account will be marked
  # as root for the storage trie so that lazy hashing works (at a later stage.)
  if acc.statement.stoTrie.isNil:
    if noisy: echo "*** persistStorage (2) pre-save",
      " clearCache=", clearCache,
      "\n    address=", acc.statement.address.toHex,
      "\n    stoTrie=", $$acc.statement.stoTrie,
      ""
    ac.ledger.merge(acc.statement)
  else:
    if noisy: echo "*** persistStorage (3)",
      " clearCache=", clearCache,
      "\n    address=", acc.statement.address.toHex,
      "\n    stoTrie=", $$acc.statement.stoTrie,
      ""
  var storageLedger = StorageLedger.init(ac.ledger, acc.statement)
  if noisy: echo "*** persistStorage (4)",
    " clearCache=", clearCache,
    "\n    address=", acc.statement.address.toHex,
    "\n    stoTrie=", $$acc.statement.stoTrie,
    "\n    stoLedger=", $$storageLedger.getTrie,
    ""
  # Save `overlayStorage[]` on database
  for slot, value in acc.overlayStorage:
    if value > 0:
      let encodedValue = rlp.encode(value)
      storageLedger.merge(slot, encodedValue)
      if noisy: echo "*** persistStorage (5) set",
        " clearCache=", clearCache,
        "\n    address=", acc.statement.address.toHex,
        "\n    slot=", slot.toHex,
        ""
    else:
      if noisy: echo "*** persistStorage (6) delete",
        " clearCache=", clearCache,
        "\n    address=", acc.statement.address.toHex,
        "\n    slot=", slot.toHex,
        ""
      storageLedger.delete(slot)
    let
      key = slot.toBytesBE.keccakHash.data.slotHashToSlotKey
      rc = ac.kvt.put(key.toOpenArray, rlp.encode(slot))
    if rc.isErr:
      warn logTxt "persistStorage()", slot, error=($$rc.error)

  if not clearCache:
    # if we preserve cache, move the overlayStorage
    # to originalStorage, related to EIP2200, EIP1283
    for slot, value in acc.overlayStorage:
      if value > 0:
        acc.originalStorage[slot] = value
      else:
        acc.originalStorage.del(slot)
    acc.overlayStorage.clear()

  if noisy: echo "*** persistStorage (9)",
    " clearCache=", clearCache,
    "\n    address=", acc.statement.address.toHex,
    "\n    prvTrie=", $$acc.statement.stoTrie,
    "\n    newTrie=", $$storageLedger.getTrie,
    ""
  acc.statement.stoTrie = storageLedger.getTrie()

proc makeDirty(ac: AccountsLedgerRef, address: EthAddress, cloneStorage = true): AccountRef =
  ac.isDirty = true
  result = ac.getAccount(address, "makeDirty")
  if address in ac.savePoint.cache:
    # it's already in latest savepoint
    result.flags.incl Dirty
    return

  # put a copy into latest savepoint
  result = result.clone(cloneStorage)
  result.flags.incl Dirty
  ac.savePoint.cache[address] = result

proc getCodeHash*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  let acc = ac.getAccount(address, "getCodeHash", false)
  if acc.isNil: emptyEthAccount.codeHash
  else: acc.statement.codeHash

proc getBalance*(ac: AccountsLedgerRef, address: EthAddress): UInt256 =
  let acc = ac.getAccount(address, "getBalance", false)
  if acc.isNil: emptyEthAccount.balance
  else: acc.statement.balance

proc getNonce*(ac: AccountsLedgerRef, address: EthAddress): AccountNonce =
  let acc = ac.getAccount(address, "getNonce", false)
  result =
    if acc.isNil: emptyEthAccount.nonce
    else: acc.statement.nonce

proc getCode*(ac: AccountsLedgerRef, address: EthAddress): seq[byte] =
  let acc = ac.getAccount(address, "getCode", false)
  if acc.isNil:
    return

  if CodeLoaded in acc.flags or CodeChanged in acc.flags:
    result = acc.code
  else:
    let rc = block:
      when defined(geth):
        ac.kvt.get(acc.statement.codeHash.data)
      else:
        ac.kvt.get(contractHashKey(acc.statement.codeHash).toOpenArray)
    if rc.isOk:
      acc.code = rc.value
      acc.flags.incl CodeLoaded
      result = acc.code

proc getCodeSize*(ac: AccountsLedgerRef, address: EthAddress): int =
  ac.getCode(address).len

proc getCommittedStorage*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): UInt256 =
  let acc = ac.getAccount(address, "getCommittedStorage", false)
  if acc.isNil:
    return
  if noisy: echo "*** getCommittedStorage (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  acc.originalStorageValue(slot, ac)

proc getStorage*(ac: AccountsLedgerRef, address: EthAddress, slot: UInt256): UInt256 =
  let acc = ac.getAccount(address, "getStorage", false)
  if acc.isNil:
    return
  acc.storageValue(slot, ac)

proc hasCodeOrNonce*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, "hasCodeOrNonce", false)
  if acc.isNil:
    return
  acc.statement.nonce != 0 or acc.statement.codeHash != EMPTY_SHA3

proc accountExists*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, "accountExists", false)
  if acc.isNil:
    return
  acc.exists()

proc isEmptyAccount*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, "isEmptyAccount", false)
  doAssert not acc.isNil
  doAssert acc.exists()
  acc.isEmpty()

proc isDeadAccount*(ac: AccountsLedgerRef, address: EthAddress): bool =
  let acc = ac.getAccount(address, "isDeadAccount", false)
  if acc.isNil:
    return true
  if not acc.exists():
    return true
  acc.isEmpty()

proc setBalance*(ac: AccountsLedgerRef, address: EthAddress, balance: UInt256) =
  let acc = ac.getAccount(address, "setBalance")
  acc.flags.incl {Alive}
  if acc.statement.balance != balance:
    let trigger = address[0] in triggerPfxSet
    if noisy and trigger: echo ">>> setBalance (9)",
      " address=", address.toHex,
      " balance=", balance
    ac.makeDirty(address).statement.balance = balance

proc addBalance*(ac: AccountsLedgerRef, address: EthAddress, delta: UInt256) =
  # EIP161: We must check emptiness for the objects such that the account
  # clearing (0,0,0 objects) can take effect.
  if delta.isZero:
    let acc = ac.getAccount(address, "addBalance")
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
  let acc = ac.getAccount(address, "setNonce")
  acc.flags.incl {Alive}
  if acc.statement.nonce != nonce:
    let trigger = address[0] in triggerPfxSet
    if noisy and trigger: echo ">>> setNonce (9)",
      " address=", address.toHex,
      " nonce=",nonce
    ac.makeDirty(address).statement.nonce = nonce

proc incNonce*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: AccountsLedgerRef, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address, "setCode")
  acc.flags.incl {Alive}
  let codeHash = keccakHash(code)
  if acc.statement.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.statement.codeHash = codeHash
    acc.code = code
    acc.flags.incl CodeChanged

proc setStorage*(ac: AccountsLedgerRef, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address, "setStorage")

  if noisy: echo "*** setStorage (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  acc.flags.incl {Alive}
  let oldValue = acc.storageValue(slot, ac)
  if oldValue != value:
    var acc = ac.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ac: AccountsLedgerRef, address: EthAddress) =
  # a.k.a createStateObject. If there is an existing account with
  # the given address, it is overwritten.

  let acc = ac.getAccount(address, "clearStorage")
  acc.flags.incl {Alive, NewlyCreated}

  if noisy: echo "*** clearStorage (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  let accHash = acc.statement.stoTrie.rootHash.valueOr: return
  if accHash != EMPTY_ROOT_HASH:
    # there is no point to clone the storage since we want to remove it
    let acc = ac.makeDirty(address, cloneStorage = false)
    acc.statement.stoTrie = CoreDbTrieRef(nil)
    if acc.originalStorage.isNil.not:
      # also clear originalStorage cache, otherwise
      # both getStorage and getCommittedStorage will
      # return wrong value
      acc.originalStorage.clear()

proc deleteAccount*(ac: AccountsLedgerRef, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  let acc = ac.getAccount(address, "deleteAccount")
  acc.kill(address)

proc selfDestruct*(ac: AccountsLedgerRef, address: EthAddress) =
  ac.setBalance(address, 0.u256)
  ac.savePoint.selfDestruct.incl address

proc selfDestruct6780*(ac: AccountsLedgerRef, address: EthAddress) =
  let acc = ac.getAccount(address, "selfDestruct", false)
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
  let acc = ac.getAccount(address, "deleteEmptyAccount", false)
  if acc.isNil:
    return
  if not acc.isEmpty:
    return
  if not acc.exists:
    return
  acc.kill(address)

proc clearEmptyAccounts(ac: AccountsLedgerRef) =
  for address, acc in ac.savePoint.cache:
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      acc.kill(address)

  # https://github.com/ethereum/EIPs/issues/716
  if ac.ripemdSpecial:
    ac.deleteEmptyAccount(RIPEMD_ADDR)
    ac.ripemdSpecial = false

proc persist*(ac: AccountsLedgerRef,
              clearEmptyAccount: bool = false,
              clearCache: bool = true) =
  var noisy = noisy
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavepoint.isNil)
  var cleanAccounts = initHashSet[EthAddress]()

  if noisy: echo "*** persist (1)",
    " clearCache=", clearCache,
    "\n    db\n    ", ac.ledger.dump,
    ""
  if clearEmptyAccount:
    ac.clearEmptyAccounts()

  for address in ac.savePoint.selfDestruct:
    ac.deleteAccount(address)

  for address, acc in ac.savePoint.cache:
    assert address == acc.statement.address # debugging only
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ac)

      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(ac, clearCache)
      ac.ledger.merge(acc.statement)

      if noisy: echo "*** persist (2) Update",
        " flags=", acc.flags,
        "\n    address=", address.toHex,
        "\n    key=", address.keccakHash.data.toHex,
        "\n    stoTrie=", $$acc.statement.stoTrie,
        ""
    of Remove:
      ac.ledger.delete address
      if not clearCache:
        cleanAccounts.incl address

      if noisy: echo "*** persist (3) Remove",
        " flags=", acc.flags,
        "\n    address=", address.toHex,
        "\n    key=", address.keccakHash.data.toHex,
        "\n    stoTrie=", $$acc.statement.stoTrie,
        ""
    of DoNothing:
      # dead man tell no tales
      # remove touched dead account from cache
      if not clearCache and Alive notin acc.flags:
        cleanAccounts.incl address

      if noisy: echo "*** persist (4) DoNothing",
        " flags=", acc.flags,
        "\n    address=", address.toHex,
        "\n    key=", address.keccakHash.data.toHex,
        "\n    stoTrie=", $$acc.statement.stoTrie,
        ""

    acc.flags = acc.flags - resetFlags

  let slSave = distinct_ledgers.noisy
  distinct_ledgers.noisy = noisy
  defer: distinct_ledgers.noisy = slSave

  if clearCache:
    ac.savePoint.cache.clear()
  else:
    for x in cleanAccounts:
      ac.savePoint.cache.del x

  ac.savePoint.selfDestruct.clear()

  # Save kvt and ledger
  ac.kvt.persistent()
  ac.ledger.persistent()

  # EIP2929
  ac.savePoint.accessList.clear()

  if noisy: echo "*** persist (9)"
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

iterator storage*(ac: AccountsLedgerRef, address: EthAddress): (UInt256, UInt256) {.gcsafe, raises: [CoreDbApiError].} =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, "storage", false)
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
  let acc = ac.getAccount(address, "cachedStorage", false)

  if noisy: echo "*** cachedStorage (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
  if not acc.isNil:
    if not acc.originalStorage.isNil:
      for k, v in acc.originalStorage:
        yield (k, v)

proc getStorageRoot*(ac: AccountsLedgerRef, address: EthAddress): Hash256 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, "getStorageRoot", false)
  if acc.isNil: EMPTY_ROOT_HASH
  else: acc.statement.stoTrie.rootHash.valueOr: EMPTY_ROOT_HASH

proc update(wd: var WitnessData, acc: AccountRef) =
  if noisy: echo "*** update (1)",
    "\n    stoTrie=", $$acc.statement.stoTrie,
    ""
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
