import
  tables, hashes, sets,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs],
  ../constants, ../utils, storage_types,
  ../../stateless/multi_keys

type
  AccountFlag = enum
    IsAlive
    IsNew
    IsDirty
    IsTouched
    IsClone
    CodeLoaded
    CodeChanged
    StorageChanged

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
    db: TrieDatabaseRef
    trie: SecureHexaryTrie
    savePoint: SavePoint
    witnessCache: Table[EthAddress, WitnessData]
    isDirty: bool

  ReadOnlyStateDB* = distinct AccountsCache

  TransactionState = enum
    Pending
    Committed
    RolledBack

  SavePoint* = ref object
    parentSavepoint: SavePoint
    cache: Table[EthAddress, RefAccount]
    state: TransactionState

const
  emptyAcc = newAccount()

  resetFlags = {
    IsDirty,
    IsNew,
    IsTouched,
    IsClone,
    CodeChanged,
    StorageChanged
    }

proc beginSavepoint*(ac: var AccountsCache): SavePoint {.gcsafe.}

# The AccountsCache is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[AccountsCache], db: TrieDatabaseRef,
           root: KeccakHash, pruneTrie: bool = true): AccountsCache =
  new result
  result.db = db
  result.trie = initSecureHexaryTrie(db, root, pruneTrie)
  result.witnessCache = initTable[EthAddress, WitnessData]()
  discard result.beginSavepoint

proc init*(x: typedesc[AccountsCache], db: TrieDatabaseRef, pruneTrie: bool = true): AccountsCache =
  init(x, db, emptyRlpHash, pruneTrie)

proc rootHash*(ac: AccountsCache): KeccakHash =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavePoint.isNil)
  # make sure all cache already committed
  doAssert(ac.isDirty == false)
  ac.trie.rootHash

proc beginSavepoint*(ac: var AccountsCache): SavePoint =
  new result
  result.cache = initTable[EthAddress, RefAccount]()
  result.state = Pending
  result.parentSavepoint = ac.savePoint
  ac.savePoint = result

proc rollback*(ac: var AccountsCache, sp: Savepoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

proc commit*(ac: var AccountsCache, sp: Savepoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ac.savePoint == sp and sp.state == Pending
  # cannot commit most inner savepoint
  doAssert not sp.parentSavepoint.isNil

  ac.savePoint = sp.parentSavepoint
  for k, v in sp.cache:
    sp.parentSavepoint.cache[k] = v
  sp.state = Committed

proc dispose*(ac: var AccountsCache, sp: Savepoint) {.inline.} =
  if sp.state == Pending:
    ac.rollback(sp)

proc safeDispose*(ac: var AccountsCache, sp: Savepoint) {.inline.} =
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
  let recordFound = ac.trie.get(address)
  if recordFound.len > 0:
    # we found it
    result = RefAccount(
      account: rlp.decode(recordFound, Account),
      flags: {IsAlive}
      )
  else:
    if not shouldCreate:
      return
    # it's a request for new account
    result = RefAccount(
      account: newAccount(),
      flags: {IsAlive, IsNew}
      )

  # cache the account
  ac.savePoint.cache[address] = result

proc clone(acc: RefAccount, cloneStorage: bool): RefAccount =
  new(result)
  result.account = acc.account
  result.flags = acc.flags + {IsClone}
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
  IsAlive in acc.flags

template createTrieKeyFromSlot(slot: UInt256): auto =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  slot.toByteArrayBE
  # Original py-evm code:
  # pad32(int_to_big_endian(slot))
  # morally equivalent to toByteRange_Unnecessary but with different types

template getAccountTrie(db: TrieDatabaseRef, acc: RefAccount): auto =
  # TODO: implement `prefix-db` to solve issue #228 permanently.
  # the `prefix-db` will automatically insert account address to the
  # underlying-db key without disturb how the trie works.
  # it will create virtual container for each account.
  # see nim-eth#9
  initSecureHexaryTrie(db, acc.account.storageRoot, false)

proc originalStorageValue(acc: RefAccount, slot: UInt256, db: TrieDatabaseRef): UInt256 =
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
    accountTrie = getAccountTrie(db, acc)
    foundRecord = accountTrie.get(slotAsKey)

  result = if foundRecord.len > 0:
            rlp.decode(foundRecord, UInt256)
          else:
            UInt256.zero()

  acc.originalStorage[slot] = result

proc storageValue(acc: RefAccount, slot: UInt256, db: TrieDatabaseRef): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, db)

proc kill(acc: RefAccount) =
  acc.flags.excl IsAlive
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
  if IsAlive in acc.flags:
    if IsNew in acc.flags or IsDirty in acc.flags:
      result = Update
  else:
    if IsNew notin acc.flags:
      result = Remove

proc persistCode(acc: RefAccount, db: TrieDatabaseRef) =
  if acc.code.len != 0:
    when defined(geth):
      db.put(acc.account.codeHash.data, acc.code)
    else:
      db.put(contractHashKey(acc.account.codeHash).toOpenArray, acc.code)

proc persistStorage(acc: RefAccount, db: TrieDatabaseRef, clearCache: bool) =
  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if not clearCache and acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  var accountTrie = getAccountTrie(db, acc)

  for slot, value in acc.overlayStorage:
    let slotAsKey = createTrieKeyFromSlot slot

    if value > 0:
      let encodedValue = rlp.encode(value)
      accountTrie.put(slotAsKey, encodedValue)
    else:
      accountTrie.del(slotAsKey)

    # map slothash back to slot value
    # see iterator storage below
    # slotHash can be obtained from accountTrie.put?
    let slotHash = keccakHash(slotAsKey)
    db.put(slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot))

  if not clearCache:
    # if we preserve cache, move the overlayStorage
    # to originalStorage, related to EIP2200, EIP1283
    for slot, value in acc.overlayStorage:
      if value > 0:
        acc.originalStorage[slot] = value
      else:
        acc.originalStorage.del(slot)
    acc.overlayStorage.clear()

  acc.account.storageRoot = accountTrie.rootHash

proc makeDirty(ac: AccountsCache, address: EthAddress, cloneStorage = true): RefAccount =
  ac.isDirty = true
  result = ac.getAccount(address)
  if address in ac.savePoint.cache:
    # it's already in latest savepoint
    result.flags.incl IsDirty
    return

  # put a copy into latest savepoint
  result = result.clone(cloneStorage)
  result.flags.incl IsDirty
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
      let data = ac.db.get(acc.account.codeHash.data)
    else:
      let data = ac.db.get(contractHashKey(acc.account.codeHash).toOpenArray)

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
  result = acc.isEmpty()

proc isDeadAccount*(ac: AccountsCache, address: EthAddress): bool =
  let acc = ac.getAccount(address, false)
  if acc.isNil:
    result = true
    return
  if not acc.exists():
    result = true
  else:
    result = acc.isEmpty()

proc setBalance*(ac: var AccountsCache, address: EthAddress, balance: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {IsTouched, IsAlive}
  if acc.account.balance != balance:
    ac.makeDirty(address).account.balance = balance

proc addBalance*(ac: var AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  ac.setBalance(address, ac.getBalance(address) + delta)

proc subBalance*(ac: var AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  ac.setBalance(address, ac.getBalance(address) - delta)

proc setNonce*(ac: var AccountsCache, address: EthAddress, nonce: AccountNonce) =
  let acc = ac.getAccount(address)
  acc.flags.incl {IsTouched, IsAlive}
  if acc.account.nonce != nonce:
    ac.makeDirty(address).account.nonce = nonce

proc incNonce*(ac: var AccountsCache, address: EthAddress) {.inline.} =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: var AccountsCache, address: EthAddress, code: seq[byte]) =
  let acc = ac.getAccount(address)
  acc.flags.incl {IsTouched, IsAlive}
  let codeHash = keccakHash(code)
  if acc.account.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.account.codeHash = codeHash
    acc.code = code
    acc.flags.incl CodeChanged

proc setStorage*(ac: var AccountsCache, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl {IsTouched, IsAlive}
  let oldValue = acc.storageValue(slot, ac.db)
  if oldValue != value:
    var acc = ac.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ac: var AccountsCache, address: EthAddress) =
  let acc = ac.getAccount(address)
  acc.flags.incl {IsTouched, IsAlive}
  if acc.account.storageRoot != emptyRlpHash:
    # there is no point to clone the storage since we want to remove it
    ac.makeDirty(address, cloneStorage = false).account.storageRoot = emptyRlpHash

proc deleteAccount*(ac: var AccountsCache, address: EthAddress) =
  # make sure all savepoints already committed
  doAssert(ac.savePoint.parentSavePoint.isNil)
  let acc = ac.getAccount(address)
  acc.kill()

proc persist*(ac: var AccountsCache, clearCache: bool = true) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavePoint.isNil)
  var cleanAccounts = initHashSet[EthAddress]()

  for address, acc in ac.savePoint.cache:
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ac.db)
      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(ac.db, clearCache)
      ac.trie.put address, rlp.encode(acc.account)
    of Remove:
      ac.trie.del address
      if not clearCache:
        #
        cleanAccounts.incl address
    of DoNothing:
      discard

    acc.flags = acc.flags - resetFlags

  if clearCache:
    ac.savePoint.cache.clear()
  else:
    for x in cleanAccounts:
      ac.savePoint.cache.del x
  ac.isDirty = false

iterator storage*(ac: AccountsCache, address: EthAddress): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ac.getAccount(address, false)
  if not acc.isNil:
    let storageRoot = acc.account.storageRoot
    var trie = initHexaryTrie(ac.db, storageRoot)

    for slotHash, value in trie:
      if slotHash.len == 0: continue
      let keyData = ac.db.get(slotHashToSlotKey(slotHash).toOpenArray)
      if keyData.len == 0: continue
      yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))

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
      if v == 0: continue
      wd.storageKeys.incl k

  for k, v in acc.overlayStorage:
    if v == 0 and k notin wd.storageKeys:
      continue
    if v == 0 and k in wd.storageKeys:
      wd.storageKeys.excl k
      continue
    wd.storageKeys.incl k

func witnessData(acc: RefAccount): WitnessData =
  result.storageKeys = initHashSet[UInt256]()
  update(result, acc)

proc collectWitnessData*(ac: var AccountsCache) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavePoint.isNil)
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
