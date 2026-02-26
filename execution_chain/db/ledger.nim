# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[tables, hashes, sets, typetraits],
  chronicles,
  results,
  minilru,
  eth/common/[addresses, hashes],
  ../utils/[mergeutils, utils],
  ../evm/code_bytes,
  ../core/eip7702,
  ../constants,
  ./[access_list as ac_access_list, core_db, storage_types],
  ./aristo/aristo_blobify

export
  code_bytes

const
  codeLruSize = 16*1024
    # An LRU cache of 16K items gives roughly 90% hit rate anecdotally on a
    # small range of test blocks - this number could be studied in more detail
    # Per EIP-170, a the code of a contract can be up to `MAX_CODE_SIZE` = 24kb,
    # which would cause a worst case of 386MB memory usage though in reality
    # code sizes are much smaller - it would make sense to study these numbers
    # in greater detail.
  slotsLruSize = 16 * 1024

type
  WitnessKey* = tuple[
    address: Address,
    slot: Opt[UInt256]
  ]

  # Maps witness keys to the codeTouched flag
  WitnessTable* = OrderedTable[WitnessKey, bool]

  BlockHashesCache* = LruCache[BlockNumber, Hash32]

  AccountFlag = enum
    Alive
    IsNew
    Dirty
    Touched
    CodeChanged
    StorageChanged
    NewlyCreated # EIP-6780: self destruct only in same transaction

  AccountFlags = set[AccountFlag]

  AccountRef = ref object
    statement: CoreDbAccount
    accPath: Hash32
    flags: AccountFlags
    code: CodeBytesRef
    originalStorage: TableRef[UInt256, UInt256]
    overlayStorage: Table[UInt256, UInt256]

  LedgerRef* = ref object
    txFrame*: CoreDbTxRef
    savePoint: LedgerSpRef

    isDirty: bool
    ripemdSpecial: bool
    storeSlotHash*: bool
    cache: Table[Address, AccountRef]
      # Second-level cache for the ledger save point, which is cleared on every
      # persist
    code: LruCache[Hash32, CodeBytesRef]
      ## The code cache provides two main benefits:
      ##
      ## * duplicate code is shared in memory beween accounts
      ## * the jump destination table does not have to be recomputed for every
      ##   execution, for commonly called called contracts
      ##
      ## The former feature is specially important in the 2.3-2.7M block range
      ## when underpriced code opcodes are being run en masse - both advantages
      ## help performance broadly as well.

    slots: LruCache[UInt256, Hash32]
      ## Because the same slots often reappear, we want to avoid writing them
      ## over and over again to the database to avoid the WAL and compation
      ## write amplification that ensues

    collectWitness: bool
    witnessKeys: WitnessTable
      ## Used to collect the keys of all read accounts, code and storage slots.
      ## Maps a tuple of address and slot (optional) to the codeTouched flag.

    blockHashes: BlockHashesCache
      ## Caches the block hashes fetched by the BLOCKHASH opcode in the EVM.
      ## Also used when building the execution witness to determine the
      ## block numbers fetched by the BLOCKHASH opcode for any given block.

  ReadOnlyLedger* = distinct LedgerRef

  LedgerSpRef* = ref object
    parentSavePoint: LedgerSpRef
    cache: Table[Address, AccountRef]
    dirty: Table[Address, AccountRef]
    selfDestruct: HashSet[Address]
    accessList: ac_access_list.AccessList

const
  emptyEthAccount = Account.init()

  resetFlags = {
    Dirty,
    IsNew,
    Touched,
    CodeChanged,
    StorageChanged,
    NewlyCreated
    }

template logTxt(info: static[string]): static[string] =
  "LedgerRef " & info

template computeAccPath(address: Address): Hash32 =
  keccak256(address.data)

template computeSlotKey(slot: UInt256): Hash32 =
  keccak256(slot.toBytesBE())

proc getAccount(
    ledger: LedgerRef;
    address: Address;
    shouldCreate = true;
      ): AccountRef =
  if ledger.collectWitness:
    let lookupKey = (address, Opt.none(UInt256))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  # search account from layers of cache
  var sp = ledger.savePoint
  while sp != nil:
    result = sp.cache.getOrDefault(address)
    if not result.isNil:
      return
    sp = sp.parentSavePoint

  if ledger.cache.pop(address, result):
    # Check second-level cache
    ledger.savePoint.cache[address] = result
    return

  # not found in cache, look into state trie
  let
    accPath = address.computeAccPath
    rc = ledger.txFrame.fetch accPath
  if rc.isOk:
    result = AccountRef(
      statement: rc.value,
      accPath:   accPath,
      flags:     {Alive})
  elif shouldCreate:
    result = AccountRef(
      statement: CoreDbAccount(
        nonce:    emptyEthAccount.nonce,
        balance:  emptyEthAccount.balance,
        codeHash: emptyEthAccount.codeHash),
      accPath:    accPath,
      flags:      {Alive, IsNew})
  else:
    return # ignore, don't cache

  # cache the account
  ledger.savePoint.cache[address] = result
  ledger.savePoint.dirty[address] = result

proc clone(acc: AccountRef, cloneStorage: bool): AccountRef =
  result = AccountRef(
    statement: acc.statement,
    accPath:   acc.accPath,
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
    ledger: LedgerRef;
      ): UInt256 =
  # share the same original storage between multiple
  # versions of account
  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()
  else:
    acc.originalStorage[].withValue(slot, val) do:
      return val[]

  # Not in the original values cache - go to the DB.
  let
    slotKey = ledger.slots.get(slot).valueOr:
      computeSlotKey(slot)
    rc = ledger.txFrame.slotFetch(acc.accPath, slotKey)
  if rc.isOk:
    result = rc.value

  acc.originalStorage[slot] = result

proc storageValue(
    acc: AccountRef;
    slot: UInt256;
    ledger: LedgerRef;
      ): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(slot, ledger)

proc kill(ledger: LedgerRef, acc: AccountRef) =
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.originalStorage = nil

  ledger.txFrame.clearStorage(acc.accPath).expect("txFrame.clearStorage works")

  acc.statement.nonce = emptyEthAccount.nonce
  acc.statement.balance = emptyEthAccount.balance
  acc.statement.codeHash = emptyEthAccount.codeHash
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

proc persistCode(acc: AccountRef, ledger: LedgerRef) =
  if acc.code.len != 0 and not acc.code.persisted:
    let rc = ledger.txFrame.put(
      contractHashKey(acc.statement.codeHash).toOpenArray, acc.code.bytes())
    if rc.isErr:
      warn logTxt "persistCode()",
       codeHash=acc.statement.codeHash, error=($$rc.error)
    else:
      # If the ledger changes rolled back entirely from the database, the ledger
      # code cache must also be cleared!
      acc.code.persisted = true

proc persistStorage(acc: AccountRef, ledger: LedgerRef) =
  const info = "persistStorage(): "

  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return

  if acc.originalStorage.isNil:
    acc.originalStorage = newTable[UInt256, UInt256]()

  # Make sure that there is an account entry on the database. This is needed by
  # `Aristo` for updating the account's storage area reference. As a side effect,
  # this action also updates the latest statement data.
  ledger.txFrame.merge(acc.accPath, acc.statement).isOkOr:
    raiseAssert info & $$error

  # Save `overlayStorage[]` on database
  for slot, value in acc.overlayStorage:
    acc.originalStorage[].withValue(slot, v):
      if v[] == value:
        continue # Avoid writing A-B-A updates

    var cached = true
    let slotKey = ledger.slots.get(slot).valueOr:
      cached = false
      let slotKey = computeSlotKey(slot)
      ledger.slots.put(slot, slotKey)
      slotKey

    if value > 0:
      ledger.txFrame.slotMerge(acc.accPath, slotKey, value).isOkOr:
        raiseAssert info & $$error

      # move the overlayStorage to originalStorage, related to EIP2200, EIP1283
      acc.originalStorage[slot] = value

    else:
      ledger.txFrame.slotDelete(acc.accPath, slotKey).isOkOr:
        raiseAssert info & $$error
      acc.originalStorage.del(slot)

    if ledger.storeSlotHash and not cached:
      # Write only if it was not cached to avoid writing the same data over and
      # over..
      let
        key = slotKey.slotHashToSlotKey
        rc = ledger.txFrame.put(key.toOpenArray, blobify(slot).data)
      if rc.isErr:
        warn logTxt "persistStorage()", slot, error=($$rc.error)

  acc.overlayStorage.clear()

proc makeDirty(ledger: LedgerRef, address: Address, cloneStorage = true): AccountRef =
  ledger.isDirty = true
  result = ledger.getAccount(address)
  if address in ledger.savePoint.cache:
    # it's already in latest savePoint
    result.flags.incl Dirty
    ledger.savePoint.dirty[address] = result
    return

  # put a copy into latest savePoint
  result = result.clone(cloneStorage)
  result.flags.incl Dirty
  ledger.savePoint.cache[address] = result
  ledger.savePoint.dirty[address] = result

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

# The LedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef): LedgerRef =
  init(x, db, false)

proc getStateRoot*(ledger: LedgerRef): Hash32 =
  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  # make sure all cache already committed
  doAssert(ledger.isDirty == false)
  ledger.txFrame.getStateRoot().expect("working database")

proc isTopLevelClean*(ledger: LedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ledger.isDirty and ledger.savePoint.parentSavePoint.isNil

proc beginSavePoint*(ledger: LedgerRef): LedgerSpRef =
  let savePoint = LedgerSpRef(
    parentSavePoint: ledger.savePoint
  )

  ledger.savePoint = savePoint

  savePoint

proc rollback*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ledger.savePoint == savePoint and not savePoint.parentSavePoint.isNil
  ledger.savePoint = savePoint.parentSavePoint

  reset(savePoint[]) # Release memory

proc commit*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ledger.savePoint == savePoint and not savePoint.parentSavePoint.isNil

  ledger.savePoint = savePoint.parentSavePoint
  ledger.savePoint.cache.mergeAndReset(savePoint.cache)
  ledger.savePoint.dirty.mergeAndReset(savePoint.dirty)
  ledger.savePoint.accessList.mergeAndReset(savePoint.accessList)
  ledger.savePoint.selfDestruct.mergeAndReset(savePoint.selfDestruct)

  savePoint.parentSavePoint = nil # Release memory

proc dispose*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  if savePoint.parentSavePoint != nil:
    ledger.rollback(savePoint)

proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef, storeSlotHash: bool, collectWitness = false): LedgerRef =
  new result
  result.txFrame = db
  result.storeSlotHash = storeSlotHash
  result.code = typeof(result.code).init(codeLruSize)
  result.slots = typeof(result.slots).init(slotsLruSize)
  result.collectWitness = collectWitness
  result.blockHashes = typeof(result.blockHashes).init(MAX_PREV_HEADER_DEPTH.int)
  discard result.beginSavePoint

proc getCodeHash*(ledger: LedgerRef, address: Address): Hash32 =
  let acc = ledger.getAccount(address, false)
  if acc.isNil: emptyEthAccount.codeHash
  else: acc.statement.codeHash

proc getBalance*(ledger: LedgerRef, address: Address): UInt256 =
  let acc = ledger.getAccount(address, false)
  if acc.isNil: emptyEthAccount.balance
  else: acc.statement.balance

proc getNonce*(ledger: LedgerRef, address: Address): AccountNonce =
  let acc = ledger.getAccount(address, false)
  if acc.isNil: emptyEthAccount.nonce
  else: acc.statement.nonce

proc getCode*(ledger: LedgerRef,
              address: Address,
              returnHash: static[bool] = false): auto =
  if ledger.collectWitness:
    let lookupKey = (address, Opt.none(UInt256))
    # We overwrite any existing record here so that codeTouched is always set to
    # true even if an account was previously accessed without touching the code
    ledger.witnessKeys[lookupKey] = true

  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    when returnHash:
      return (EMPTY_CODE_HASH, CodeBytesRef())
    else:
      return CodeBytesRef()

  if acc.code == nil:
    acc.code =
      if acc.statement.codeHash != EMPTY_CODE_HASH:
        ledger.code.get(acc.statement.codeHash).valueOr:
          var rc = ledger.txFrame.get(contractHashKey(acc.statement.codeHash).toOpenArray)
          if rc.isErr:
            warn logTxt "getCode()", codeHash=acc.statement.codeHash, error=($$rc.error)
            CodeBytesRef()
          else:
            let newCode = CodeBytesRef.init(move(rc.value), persisted = true)
            ledger.code.put(acc.statement.codeHash, newCode)
            newCode
      else:
        CodeBytesRef()

  when returnHash:
    (acc.statement.codeHash, acc.code)
  else:
    acc.code

proc getCodeSize*(ledger: LedgerRef, address: Address): int =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return 0

  if acc.code == nil:
    if acc.statement.codeHash == EMPTY_CODE_HASH:
      return 0
    acc.code = ledger.code.get(acc.statement.codeHash).valueOr:
      # On a cache miss, we don't fetch the code - instead, we fetch just the
      # length - should the code itself be needed, it will typically remain
      # cached and easily accessible in the database layer - this is to prevent
      # EXTCODESIZE calls from messing up the code cache and thus causing
      # recomputation of the jump destination table
      var rc = ledger.txFrame.len(contractHashKey(acc.statement.codeHash).toOpenArray)

      return rc.valueOr:
        warn logTxt "getCodeSize()", codeHash=acc.statement.codeHash, error=($$rc.error)
        0

  acc.code.len()

proc resolveCode*(ledger: LedgerRef, address: Address): CodeBytesRef =
  let code = ledger.getCode(address)
  let delegateTo = parseDelegationAddress(code).valueOr:
    return code
  ledger.getCode(delegateTo)

proc getCommittedStorage*(ledger: LedgerRef, address: Address, slot: UInt256): UInt256 =
  let acc = ledger.getAccount(address, false)

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  if acc.isNil:
    return
  acc.originalStorageValue(slot, ledger)

proc getStorage*(ledger: LedgerRef, address: Address, slot: UInt256): UInt256 =
  let acc = ledger.getAccount(address, false)

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  if acc.isNil:
    return
  acc.storageValue(slot, ledger)

proc contractCollision*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return
  acc.statement.nonce != 0 or
    acc.statement.codeHash != EMPTY_CODE_HASH or
      not ledger.txFrame.slotStorageEmptyOrVoid(acc.accPath)

proc accountExists*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return
  acc.exists()

proc isEmptyAccount*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  doAssert not acc.isNil
  doAssert acc.exists()
  acc.isEmpty()

proc isDeadAccount*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return true
  if not acc.exists():
    return true
  acc.isEmpty()

proc setBalance*(ledger: LedgerRef, address: Address, balance: UInt256) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {Alive}
  if acc.statement.balance != balance:
    ledger.makeDirty(address).statement.balance = balance

proc addBalance*(ledger: LedgerRef, address: Address, delta: UInt256) =
  # EIP161: We must check emptiness for the objects such that the account
  # clearing (0,0,0 objects) can take effect.
  if delta.isZero:
    let acc = ledger.getAccount(address)
    if acc.isEmpty:
      ledger.makeDirty(address).flags.incl Touched
    return
  ledger.setBalance(address, ledger.getBalance(address) + delta)

proc subBalance*(ledger: LedgerRef, address: Address, delta: UInt256) =
  if delta.isZero:
    # This zero delta early exit is important as shown in EIP-4788.
    # If the account is created, it will change the state.
    # But early exit will prevent the account creation.
    # In this case, the SYSTEM_ADDRESS
    return
  ledger.setBalance(address, ledger.getBalance(address) - delta)

proc setNonce*(ledger: LedgerRef, address: Address, nonce: AccountNonce) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {Alive}
  if acc.statement.nonce != nonce:
    ledger.makeDirty(address).statement.nonce = nonce

proc incNonce*(ledger: LedgerRef, address: Address) =
  ledger.setNonce(address, ledger.getNonce(address) + 1)

proc setCode*(ledger: LedgerRef, address: Address, code: seq[byte]) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {Alive}
  let codeHash = keccak256(code)
  if acc.statement.codeHash != codeHash:
    var acc = ledger.makeDirty(address)
    acc.statement.codeHash = codeHash
    # Try to reuse cache entry if it exists, but don't save the code - it's not
    # a given that it will be executed within LRU range
    acc.code = ledger.code.get(codeHash).valueOr(CodeBytesRef.init(code))
    acc.flags.incl CodeChanged

proc setStorage*(ledger: LedgerRef, address: Address, slot, value: UInt256) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {Alive}

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  let oldValue = acc.storageValue(slot, ledger)
  if oldValue != value:
    var acc = ledger.makeDirty(address)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ledger: LedgerRef, address: Address) =
  const info = "clearStorage(): "

  # If there is an existing account with the given address, it is overwritten.
  let acc = ledger.getAccount(address)
  acc.flags.incl {Alive, NewlyCreated}

  let empty = ledger.txFrame.slotStorageEmpty(acc.accPath).valueOr: return
  if not empty:
    # need to clear the storage from the database first
    let acc = ledger.makeDirty(address, cloneStorage = false)
    ledger.txFrame.clearStorage(acc.accPath).isOkOr:
      raiseAssert info & $$error
    # update caches
    if acc.originalStorage.isNil.not:
      # also clear originalStorage cache, otherwise
      # both getStorage and getCommittedStorage will
      # return wrong value
      acc.originalStorage.clear()

proc deleteAccount(ledger: LedgerRef, address: Address) =
  # make sure all savePoints already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  let acc = ledger.getAccount(address)
  ledger.savePoint.dirty[address] = acc
  ledger.kill acc

proc selfDestruct*(ledger: LedgerRef, address: Address) =
  ledger.setBalance(address, 0.u256)
  ledger.savePoint.selfDestruct.incl address

proc selfDestruct6780*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return false

  if NewlyCreated in acc.flags:
    ledger.selfDestruct(address)
    true
  else:
    false

proc selfDestructLen*(ledger: LedgerRef): int =
  ledger.savePoint.selfDestruct.len

iterator nonZeroSelfDestructAccounts*(ledger: LedgerRef): (Address, UInt256) =
  for address in ledger.savePoint.selfDestruct:
    let value = ledger.getBalance(address)
    if value.isZero:
      continue
    yield (address, value)

proc ripemdSpecial*(ledger: LedgerRef) =
  ledger.ripemdSpecial = true

proc clearEmptyAccounts(ledger: LedgerRef) =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  for acc in ledger.savePoint.dirty.values():
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      ledger.kill acc

  # https://github.com/ethereum/EIPs/issues/716
  if ledger.ripemdSpecial:
    let acc = ledger.getAccount(RIPEMD_ADDR, false)
    if not acc.isNil and acc.isEmpty and acc.exists:
      ledger.savePoint.dirty[RIPEMD_ADDR] = acc
      ledger.kill acc

    ledger.ripemdSpecial = false

template getWitnessKeys*(ledger: LedgerRef): WitnessTable =
  ledger.witnessKeys

template clearWitnessKeys*(ledger: LedgerRef) =
  ledger.witnessKeys.clear()

proc getBlockHash*(ledger: LedgerRef, blockNumber: BlockNumber): Hash32 =
  ledger.blockHashes.get(blockNumber).valueOr:
    let blockHash = ledger.txFrame.getBlockHash(blockNumber).valueOr:
      default(Hash32)

    ledger.blockHashes.put(blockNumber, blockHash)
    blockHash

template getBlockHashesCache*(ledger: LedgerRef): BlockHashesCache =
  ledger.blockHashes

proc clearBlockHashesCache*(ledger: LedgerRef) =
  if ledger.blockHashes.len() > 0:
    ledger.blockHashes = BlockHashesCache.init(MAX_PREV_HEADER_DEPTH.int)

proc persist*(ledger: LedgerRef,
              clearEmptyAccount: bool = false,
              clearCache = false,
              clearWitness = false) =
  const info = "persist(): "

  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)

  if clearEmptyAccount:
    ledger.clearEmptyAccounts()

  for address in ledger.savePoint.selfDestruct:
    ledger.deleteAccount(address)

  for (address, acc) in ledger.savePoint.dirty.pairs(): # This is a hotspot in block processing
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ledger)
      if StorageChanged in acc.flags:
        acc.persistStorage(ledger)
      else:
        # This one is only necessary unless `persistStorage()` is run which needs
        # to `merge()` the latest statement as well.
        ledger.txFrame.merge(acc.accPath, acc.statement).isOkOr:
          raiseAssert info & $$error
    of Remove:
      ledger.txFrame.delete(acc.accPath).isOkOr:
        if error.error != AccNotFound:
          raiseAssert info & $$error
      ledger.savePoint.cache.del address
    of DoNothing:
      # dead man tell no tales
      # remove touched dead account from cache
      if Alive notin acc.flags:
        ledger.savePoint.cache.del address

    acc.flags = acc.flags - resetFlags
  ledger.savePoint.dirty.clear()

  if clearCache:
    # This overwrites the cache from the previous persist, providing a crude LRU
    # scheme with little overhead
    # TODO https://github.com/nim-lang/Nim/issues/23759
    swap(ledger.cache, ledger.savePoint.cache)
    ledger.savePoint.cache.reset()

  ledger.savePoint.selfDestruct.clear()

  # EIP2929
  ledger.savePoint.accessList.clear()

  ledger.isDirty = false

  if clearWitness:
    ledger.clearWitnessKeys()
    ledger.clearBlockHashesCache()

iterator addresses*(ledger: LedgerRef): Address =
  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  for address, _ in ledger.savePoint.cache:
    yield address

iterator accounts*(ledger: LedgerRef): Account =
  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  for _, acc in ledger.savePoint.cache:
    yield ledger.txFrame.recast(
      acc.accPath, acc.statement).value

iterator pairs*(ledger: LedgerRef): (Address, Account) =
  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  for address, acc in ledger.savePoint.cache:
    yield (address, ledger.txFrame.recast(
      acc.accPath, acc.statement).value)

iterator storage*(
    ledger: LedgerRef;
    address: Address;
      ): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  for (slotHash, value) in ledger.txFrame.slotPairs address.computeAccPath:
    let rc = ledger.txFrame.get(slotHashToSlotKey(slotHash).toOpenArray)
    if rc.isErr:
      warn logTxt "storage()", slotHash, error=($$rc.error)
      continue
    let r = deblobify(rc.value, UInt256)
    if r.isErr:
      warn logTxt "storage.deblobify", slotHash, msg=r.error
      continue
    yield (r.value, value)

iterator cachedStorage*(ledger: LedgerRef, address: Address): (UInt256, UInt256) =
  let acc = ledger.getAccount(address, false)
  if not acc.isNil:
    if not acc.originalStorage.isNil:
      for k, v in acc.originalStorage:
        yield (k, v)

proc getStorageRoot*(ledger: LedgerRef, address: Address): Hash32 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ledger.getAccount(address, false)
  if acc.isNil: EMPTY_ROOT_HASH
  else: ledger.txFrame.slotStorageRoot(acc.accPath).valueOr: EMPTY_ROOT_HASH

proc accessList*(ledger: LedgerRef, address: Address) =
  ledger.savePoint.accessList.add(address)

proc accessList*(ledger: LedgerRef, address: Address, slot: UInt256) =
  ledger.savePoint.accessList.add(address, slot)

func inAccessList*(ledger: LedgerRef, address: Address): bool =
  var sp = ledger.savePoint
  while sp != nil:
    result = sp.accessList.contains(address)
    if result:
      return
    sp = sp.parentSavePoint

func inAccessList*(ledger: LedgerRef, address: Address, slot: UInt256): bool =
  var sp = ledger.savePoint
  while sp != nil:
    result = sp.accessList.contains(address, slot)
    if result:
      return
    sp = sp.parentSavePoint

func getAccessList*(ledger: LedgerRef): transactions.AccessList =
  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  ledger.savePoint.accessList.getAccessList()

proc getEthAccount*(ledger: LedgerRef, address: Address): Account =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return emptyEthAccount

  ## Convert to legacy object, will throw an assert if that fails
  let rc = ledger.txFrame.recast(acc.accPath, acc.statement)
  if rc.isErr:
    raiseAssert "getAccount(): cannot convert account: " & $$rc.error
  rc.value

proc getAccountProof*(ledger: LedgerRef, address: Address): seq[seq[byte]] =
  let accProof = ledger.txFrame.proof(address.computeAccPath).valueOr:
    raiseAssert "Failed to get account proof: " & $$error

  accProof[0]

proc getStorageProof*(ledger: LedgerRef, address: Address, slots: openArray[UInt256]): seq[seq[seq[byte]]] =
  let
    addressHash = address.computeAccPath
    accountExists = ledger.txFrame.hasPath(addressHash).valueOr:
      raiseAssert "Call to hasPath failed: " & $$error

  if not accountExists:
    let emptyProofs = newSeq[seq[seq[byte]]](slots.len)
    return emptyProofs

  var slotKeys: seq[Hash32]
  for slot in slots:
    let slotKey = ledger.slots.get(slot).valueOr:
      computeSlotKey(slot)
    slotKeys.add(slotKey)

  ledger.txFrame.slotProofs(addressHash, slotKeys).valueOr:
    raiseAssert "Failed to get slot proof: " & $$error

# ------------------------------------------------------------------------------
# Public virtual read-only methods
# ------------------------------------------------------------------------------

proc getStateRoot*(ledger: ReadOnlyLedger): Hash32 {.borrow.}
proc getCodeHash*(ledger: ReadOnlyLedger, address: Address): Hash32 = getCodeHash(distinctBase ledger, address)
proc getStorageRoot*(ledger: ReadOnlyLedger, address: Address): Hash32 = getStorageRoot(distinctBase ledger, address)
proc getBalance*(ledger: ReadOnlyLedger, address: Address): UInt256 = getBalance(distinctBase ledger, address)
proc getStorage*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): UInt256 = getStorage(distinctBase ledger, address, slot)
proc getNonce*(ledger: ReadOnlyLedger, address: Address): AccountNonce = getNonce(distinctBase ledger, address)
proc getCode*(ledger: ReadOnlyLedger, address: Address): CodeBytesRef = getCode(distinctBase ledger, address)
proc getCodeSize*(ledger: ReadOnlyLedger, address: Address): int = getCodeSize(distinctBase ledger, address)
proc contractCollision*(ledger: ReadOnlyLedger, address: Address): bool = contractCollision(distinctBase ledger, address)
proc accountExists*(ledger: ReadOnlyLedger, address: Address): bool = accountExists(distinctBase ledger, address)
proc isDeadAccount*(ledger: ReadOnlyLedger, address: Address): bool = isDeadAccount(distinctBase ledger, address)
proc isEmptyAccount*(ledger: ReadOnlyLedger, address: Address): bool = isEmptyAccount(distinctBase ledger, address)
proc getCommittedStorage*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): UInt256 = getCommittedStorage(distinctBase ledger, address, slot)
proc inAccessList*(ledger: ReadOnlyLedger, address: Address): bool = inAccessList(distinctBase ledger, address)
proc inAccessList*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): bool = inAccessList(distinctBase ledger, address)
proc getAccountProof*(ledger: ReadOnlyLedger, address: Address): seq[seq[byte]] = getAccountProof(distinctBase ledger, address)
proc getStorageProof*(ledger: ReadOnlyLedger, address: Address, slots: openArray[UInt256]): seq[seq[seq[byte]]] = getStorageProof(distinctBase ledger, address, slots)
proc resolveCode*(ledger: ReadOnlyLedger, address: Address): CodeBytesRef = resolveCode(distinctBase ledger, address)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
