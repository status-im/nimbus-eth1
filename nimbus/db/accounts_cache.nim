import
  tables, hashes, sets,
  eth/[common, rlp], eth/trie/[hexary, db, trie_defs],
  ../constants, ../utils, storage_types

type
  AccountFlag = enum
    IsAlive
    IsNew
    IsDirty
    IsTouched
    CodeLoaded
    CodeChanged
    StorageChanged

  AccountFlags = set[AccountFlag]

  RefAccount = ref object
    account: Account
    flags: AccountFlags
    code: ByteRange
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]

  AccountsCache* = object
    db: TrieDatabaseRef
    trie: SecureHexaryTrie
    savePoint: SavePoint
    unrevertablyTouched: HashSet[EthAddress]

  TransactionState = enum
    Pending
    Committed
    RolledBack

  SavePoint* = ref object
    ac: AccountsCache
    parentSavepoint: SavePoint
    cache: Table[EthAddress, RefAccount]
    state: TransactionState

proc beginTransaction*(ac: var AccountsCache): SavePoint {.gcsafe.}

# The AccountsCache is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[AccountsCache], db: TrieDatabaseRef,
           root: KeccakHash, pruneTrie: bool): AccountsCache =
  result.db = db
  result.trie = initSecureHexaryTrie(db, root, pruneTrie)
  result.unrevertablyTouched = initHashSet[EthAddress]()
  discard result.beginTransaction

proc beginTransaction*(ac: var AccountsCache): SavePoint =
  new result
  result.ac = ac
  result.cache = initTable[EthAddress, RefAccount]()
  result.state = Pending
  result.parentSavepoint = ac.savePoint
  ac.savePoint = result

proc rollback*(sp: Savepoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert sp.ac.savePoint == sp and sp.state == Pending
  sp.ac.savePoint = sp.parentSavepoint
  sp.state = RolledBack

proc commit*(sp: Savepoint) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert sp.ac.savePoint == sp and sp.state == Pending
  sp.ac.savePoint = sp.parentSavepoint
  if isNil sp.parentSavepoint:
    # cannot commit most inner savepoint
    doAssert(false)
  else:
    for k, v in sp.cache:
      sp.parentSavepoint.cache[k] = v
  sp.state = Committed

proc dispose*(sp: Savepoint) {.inline.} =
  if sp.state == Pending:
    sp.rollback()

proc safeDispose*(sp: Savepoint) {.inline.} =
  if (not isNil(sp)) and (sp.state == Pending):
    sp.rollback()

template createRangeFromAddress(address: EthAddress): ByteRange =
  ## XXX: The name of this proc is intentionally long, because it
  ## performs a memory allocation and data copying that may be eliminated
  ## in the future. Avoid renaming it to something similar as `toRange`, so
  ## it can remain searchable in the code.
  toRange(@address)

proc getAccount(ac: AccountsCache, address: EthAddress): RefAccount =
  # search account from layers of cache
  var sp = ac.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavepoint

  # not found in cache, look into state trie
  let recordFound = ac.trie.get(createRangeFromAddress address)
  if recordFound.len > 0:
    # we found it
    result = RefAccount(
      account: rlp.decode(recordFound, Account),
      flags: {IsAlive}
      )
  else:
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
  result.flags = acc.flags
  result.code = acc.code

  if cloneStorage:
    result.originalStorage = acc.originalStorage
    if acc.overlayStorage.len > 0:
      let initialLength = tables.rightSize(acc.overlayStorage.len)
      result.overlayStorage = initTable[UInt256, UInt256](initialLength)
      for k, v in acc.overlayStorage:
        result.overlayStorage[k] = v

  result.flags.incl IsDirty

proc isEmpty(acc: RefAccount): bool =
  result = acc.account.codeHash == EMPTY_SHA3 and
    acc.account.balance.isZero and
    acc.account.nonce == 0

template createTrieKeyFromSlot(slot: UInt256): ByteRange =
  # XXX: This is too expensive. Similar to `createRangeFromAddress`
  # Converts a number to hex big-endian representation including
  # prefix and leading zeros:
  @(slot.toByteArrayBE).toRange
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
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    if slot in acc.originalStorage:
      result = acc.originalStorage[slot]
      return

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
  if slot in acc.overlayStorage:
    return acc.overlayStorage[slot]

  acc.originalStorageValue(slot, db)

proc kill(acc: RefAccount) =
  acc.flags.excl IsAlive
  acc.overlayStorage.clear()
  acc.originalStorage.clear()
  acc.account = newAccount()
  acc.code = default(ByteRange)

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
    db.put(contractHashKey(acc.account.codeHash).toOpenArray, acc.code.toOpenArray)

proc persistStorage(acc: RefAccount, db: TrieDatabaseRef) =
  var accountTrie = getAccountTrie(db, acc)

  for slot, value in acc.overlayStorage:
    let slotAsKey = createTrieKeyFromSlot slot

    if value > 0:
      let encodedValue = rlp.encode(value).toRange
      accountTrie.put(slotAsKey, encodedValue)
    else:
      accountTrie.del(slotAsKey)

    # map slothash back to slot value
    # see iterator storage below
    # slotHash can be obtained from accountTrie.put?
    let slotHash = keccakHash(slotAsKey.toOpenArray)
    db.put(slotHashToSlotKey(slotHash.data).toOpenArray, rlp.encode(slot))
  acc.account.storageRoot = accountTrie.rootHash

proc makeDirty(ac: AccountsCache, address: EthAddress, cloneStorage = true): RefAccount =
  result = ac.getAccount(address)
  if address in ac.savePoint.cache:
    # it's in latest savepoint
    result.flags.incl IsDirty
    return

  # put a copy into latest savepoint
  result = result.clone(cloneStorage)
  result.flags.incl IsDirty
  ac.savePoint.cache[address] = result

proc getCodeHash*(ac: AccountsCache, address: EthAddress): Hash256 {.inline.} =
  ac.getAccount(address).account.codeHash

proc getBalance*(ac: AccountsCache, address: EthAddress): UInt256 {.inline.} =
  ac.getAccount(address).account.balance

proc getNonce*(ac: AccountsCache, address: EthAddress): AccountNonce {.inline.} =
  ac.getAccount(address).account.nonce

proc getCode*(ac: AccountsCache, address: EthAddress): ByteRange =
  let acc = ac.getAccount(address)
  if CodeLoaded in acc.flags or CodeChanged in acc.flags:
    result = acc.code
  else:
    let data = ac.db.get(contractHashKey(acc.account.codeHash).toOpenArray)
    acc.code = data.toRange
    acc.flags.incl CodeLoaded
    result = acc.code

proc getCodeSize*(ac: AccountsCache, address: EthAddress): int {.inline.} =
  ac.getCode(address).len

proc getCommittedStorage*(ac: AccountsCache, address: EthAddress, slot: UInt256): UInt256 {.inline.} =
  let acc = ac.getAccount(address)
  acc.originalStorageValue(slot, ac.db)

proc getStorage*(ac: AccountsCache, address: EthAddress, slot: UInt256): UInt256 {.inline.} =
  let acc = ac.getAccount(address)
  acc.storageValue(slot, ac.db)

proc hasCodeOrNonce*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address)
  acc.account.nonce != 0 or acc.account.codeHash != EMPTY_SHA3

proc accountExists*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address)
  result = IsNew notin acc.flags

proc isEmptyAccount*(ac: AccountsCache, address: EthAddress): bool {.inline.} =
  let acc = ac.getAccount(address)
  doAssert IsNew notin acc.flags
  result = acc.isEmpty()

proc isDeadAccount*(ac: AccountsCache, address: EthAddress): bool =
  let acc = ac.getAccount(address)
  if IsNew in acc.flags:
    result = true
  else:
    result = acc.isEmpty()

proc setBalance*(ac: var AccountsCache, address: EthAddress, balance: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl IsTouched
  if acc.account.balance != balance:
    ac.makeDirty(address).account.balance = balance

proc addBalance*(ac: var AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  ac.setBalance(address, ac.getBalance(address) + delta)

proc subBalance*(ac: var AccountsCache, address: EthAddress, delta: UInt256) {.inline.} =
  ac.setBalance(address, ac.getBalance(address) - delta)

proc setNonce*(ac: var AccountsCache, address: EthAddress, nonce: AccountNonce) =
  let acc = ac.getAccount(address)
  acc.flags.incl IsTouched
  if acc.account.nonce != nonce:
    ac.makeDirty(address).account.nonce = nonce

proc incNonce*(ac: var AccountsCache, address: EthAddress) {.inline.} =
  ac.setNonce(address, ac.getNonce(address) + 1)

proc setCode*(ac: var AccountsCache, address: EthAddress, code: ByteRange) =
  let acc = ac.getAccount(address)
  acc.flags.incl IsTouched
  let codeHash = keccakHash(code.toOpenArray)
  if acc.account.codeHash != codeHash:
    var acc = ac.makeDirty(address)
    acc.account.codeHash = codeHash
    acc.code = code
    acc.flags.incl CodeChanged

proc setStorage*(ac: var AccountsCache, address: EthAddress, slot, value: UInt256) =
  let acc = ac.getAccount(address)
  acc.flags.incl IsTouched
  let oldValue = acc.storageValue(slot, ac.db)
  if oldValue != value:
    var acc = ac.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ac: var AccountsCache, address: EthAddress) =
  let acc = ac.getAccount(address)
  acc.flags.incl IsTouched
  if acc.account.storageRoot != emptyRlpHash:
    # there is no point to clone the storage since we want to remove it
    ac.makeDirty(address, cloneStorage = false).account.storageRoot = emptyRlpHash

proc unrevertableTouch*(ac: var AccountsCache, address: EthAddress) =
  ac.unrevertablyTouched.incl address

proc removeEmptyAccounts*(ac: var AccountsCache) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavePoint.isNil)
  for _, acc in ac.savePoint.cache:
    if IsTouched in acc.flags and acc.isEmpty:
      acc.kill()

  for address in ac.unrevertablyTouched:
    var acc = ac.getAccount(address)
    if acc.isEmpty:
      acc.kill()

proc persist*(ac: var AccountsCache) =
  # make sure all savepoint already committed
  doAssert(ac.savePoint.parentSavePoint.isNil)
  for address, acc in ac.savePoint.cache:
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ac.db)
      if StorageChanged in acc.flags:
        # storageRoot must be updated first
        # before persisting account into merkle trie
        acc.persistStorage(ac.db)
      ac.trie.put createRangeFromAddress(address), rlp.encode(acc.account).toRange
    of Remove:
      ac.trie.del createRangeFromAddress(address)
    of DoNothing:
      discard

iterator storage*(ac: AccountsCache, address: EthAddress): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let storageRoot = ac.getAccount(address).account.storageRoot
  var trie = initHexaryTrie(ac.db, storageRoot)

  for slot, value in trie:
    if slot.len != 0:
      var keyData = ac.db.get(slotHashToSlotKey(slot.toOpenArray).toOpenArray).toRange
      yield (rlp.decode(keyData, UInt256), rlp.decode(value, UInt256))
