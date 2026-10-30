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
  eth/common/[addresses, hashes, block_access_lists],
  ../utils/[mergeutils, utils],
  ../evm/code_bytes,
  ../concurrency/maybe_owned,
  ../constants,
  ../block_access_list/[bal_overlay, bal_utils],
  ./[access_list as ac_access_list, core_db, storage_types],
  ./aristo/[aristo_blobify, aristo_desc, aristo_get]

export
  code_bytes, core_db.computeAccPath, core_Db.computeSlotKey

const
  codeLruSize = 16*1024
    # An LRU cache of 16K items gives roughly 90% hit rate anecdotally on a
    # small range of test blocks - this number could be studied in more detail
    # Since EIP-7954, the code of a contract can be up to
    # `EIP7954_MAX_CODE_SIZE` = 64kb (24kb before, per EIP-170), which would
    # cause a worst case of 1GB memory usage though in reality code sizes are
    # much smaller - it would make sense to study these numbers in greater
    # detail.
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
    LeafExists
    IsNew
    Dirty
    Touched
    CodeChanged
    StorageChanged
    StatementChanged
    NewlyCreated # EIP-6780: self destruct only in same transaction
    ClearAccountPreserveBalance

  AccountFlags = set[AccountFlag]

  # Store original value from the database
  OriginalValueRef = ref object
    statement: CoreDbAccount
    storage:   Table[UInt256, UInt256]
    code: CodeBytesRef

  AccountRef* = ref object
    statement: CoreDbAccount
    accPath: Hash32
    flags: AccountFlags
    code: CodeBytesRef
    original: OriginalValueRef
    overlayStorage: Table[UInt256, UInt256]

  LedgerRef* = ref object
    txFrameRef: MaybeOwned[CoreDbTxRef]
    savePoint: LedgerSpRef

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

    holdCode*: bool
      ## Keep the code `persist` would write in `heldCode` until
      ## `storeHeldCode`. Database writes are immediate and outlive the frame,
      ## so callers set this when the block may still be dropped.

    heldCode: Table[Hash32, CodeBytesRef]

    collectWitness*: bool

    witnessKeys: WitnessTable
      ## Used to collect the keys of all read accounts, code and storage slots.
      ## Maps a tuple of address and slot (optional) to the codeTouched flag.

    stateless*: bool
      ## Selects how a fatal condition detected during execution (see fatalError)
      ## is handled. Under stateless execution the used witness is untrusted, so
      ## it may be invalid or incomplete. A fatal condition then must stop the
      ## block execution with a validation error. On a full node the state is
      ## complete, so it is instead a defect (assert).

    fatalError*: Opt[string]
      ## Set when a fatal block-aborting condition is detected during execution
      ## that cannot travel the EVM's transaction-level error channel (which is
      ## absorbed by the calling frame as a reverted CALL). Checked and acted on
      ## in processTransaction (see the stateless flag).

    blockHashes: BlockHashesCache
      ## Caches the block hashes fetched by the BLOCKHASH opcode in the EVM.
      ## Also used when building the execution witness to determine the
      ## block numbers fetched by the BLOCKHASH opcode for any given block.

    balOverlay*: Opt[BlockAccessListOverlay]
      ## For Parallel execution using BALs, when executing each transaction
      ## we need to read from the writes in the BAL in order to have the
      ## correct pre-state. The BAL overlay enables searching for the last write
      ## in the BAL for accounts, storage and code. Only the first lookup of
      ## a balance, nonce, code or storage slot hits the overlay and then after
      ## that the values will be returned from the ledger caches. The intention
      ## is that a separate ledger instance is used for each transaction each having
      ## its own overlay instance for the given BAL index.

  ReadOnlyLedger* = distinct LedgerRef

  LedgerSpRef* = ref object
    parentSavePoint: LedgerSpRef
    cache: Table[Address, AccountRef]
    dirty: Table[Address, AccountRef]
    selfDestruct: HashSet[Address]
    accessList: ac_access_list.AccessList
    pendingCode: Table[Hash32, CodeBytesRef]
      ## Executed initcode awaiting successful commit of all enclosing frames.
    writtenCode: Table[Hash32, CodeBytesRef]
      ## Code set in this savepoint, by code hash (stateless execution and
      ## witness collection only). Reads of that hash later in the block are
      ## served from it, so the witness omits that code.

const
  resetFlags = {
    Dirty,
    IsNew,
    Touched,
    CodeChanged,
    StorageChanged,
    StatementChanged,
    NewlyCreated,
    ClearAccountPreserveBalance
    }

  EMPTY_STATEMENT = CoreDbAccount(
    nonce:    EMPTY_ACCOUNT.nonce,
    balance:  EMPTY_ACCOUNT.balance,
    codeHash: EMPTY_ACCOUNT.codeHash,
  )

template logTxt(info: static[string]): static[string] =
  "LedgerRef " & info

template txFrame*(ledger: LedgerRef): CoreDbTxRef =
  ledger.txFrameRef.get()

func `txFrame=`*(ledger: LedgerRef, txFrame: CoreDbTxRef) =
  ledger.txFrameRef.own(txFrame)

func borrowTxFrame*(ledger: LedgerRef, txFrame: CoreDbTxRef) =
  ledger.txFrameRef.borrow(txFrame)

const
  MissingNodeErrors = {HikeBranchUnresolvedEdge, HikeDanglingEdge}
    ## A trie node this read's path needs is missing locally, so unlike a
    ## proof of absence we can't tell if the account/slot exists. Covers an
    ## incomplete witness (stateless) or a not-yet-fetched trie (verified proxy).

proc applyOverlay(ledger: LedgerRef, address: Address, acc: AccountRef) =
  let overlayAcc = ledger.balOverlay.expect("bal overlay enabled").getAccount(address)
  if overlayAcc.balance.isSome():
    acc.statement.balance = overlayAcc.balance[]
  if overlayAcc.nonce.isSome():
    acc.statement.nonce = overlayAcc.nonce[]
  if overlayAcc.code.isSome():
    acc.statement.codeHash = keccak256(overlayAcc.code[])
    acc.code = CodeBytesRef.init(overlayAcc.code[])
    acc.flags.incl CodeChanged

proc isEmpty(acc: AccountRef): bool =
  acc.statement.nonce == 0 and
    acc.statement.balance.isZero and
    acc.statement.codeHash == EMPTY_CODE_HASH

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
    rc = ledger.txFrame.fetchAccount accPath

  if rc.isErr and rc.error.isAristo and rc.error.aErr in MissingNodeErrors:
    # Record a fatalError: never assert here, always fall through to the normal
    # "not found" path. The async EVM (verified proxy) relies on that.
    warn logTxt "getAccount()", address, error = ($$rc.error)
    ledger.fatalError = Opt.some(
      "getAccount(): witness missing an internal trie node required to resolve account " & $address)

  if rc.isOk:
    # Acc found in the database
    result = AccountRef(
      statement: rc.value,
      accPath:   accPath,
      flags:     {LeafExists},
    )

  if ledger.balOverlay.isSome() and ledger.balOverlay[].hasAccount(address):
    # Acc found in the BAL overlay
    if result.isNil():
      result = AccountRef(
        statement: EMPTY_STATEMENT,
        accPath:   accPath,
        flags:    {LeafExists}
      )
    ledger.applyOverlay(address, result)
    # If the account from the overlay is empty, it was self destructed
    # and so we treat it as such.
    if result.isEmpty():
      result = nil

  if not result.isNil:
    result.original = OriginalValueRef(
      statement: result.statement,
      code: result.code,
    )
  elif shouldCreate:
    result = AccountRef(
      statement: EMPTY_STATEMENT,
      accPath:    accPath,
      flags:      {LeafExists, IsNew},
      original: OriginalValueRef(
        statement: EMPTY_STATEMENT,
      )
    )
  else:
    return # ignore, don't cache

  # cache the account
  ledger.savePoint.cache[address] = result

proc clone(acc: AccountRef, cloneStorage: bool): AccountRef =
  result = AccountRef(
    statement: acc.statement,
    accPath:   acc.accPath,
    flags:     acc.flags,
    code:      acc.code,
    original:  acc.original,
  )

  if cloneStorage:
    # it's ok to clone a table this way
    result.overlayStorage = acc.overlayStorage

template exists(acc: AccountRef): bool =
  LeafExists in acc.flags

template fetchSlotChecked(ledger: LedgerRef, accPath: Hash32, slotKey: Hash32): UInt256 =
  ## Like `fetchSlot`, but a witness gap on the slot's path is a fatal
  ## condition rather than a silent `0`. Records the condition without an
  ## early return, same reasoning as `getAccount`.
  let slotRc = ledger.txFrame.fetchSlot(accPath, slotKey)
  if slotRc.isErr:
    if slotRc.error.isAristo and slotRc.error.aErr in MissingNodeErrors:
      warn logTxt "fetchSlot()", error = ($$slotRc.error)
      ledger.fatalError = Opt.some(
        "fetchSlot(): witness missing an internal trie node required to resolve storage slot")
    0'u256
  else:
    slotRc.value

proc originalStorageValue(
    acc: AccountRef;
    address: Address;
    slot: UInt256;
    ledger: LedgerRef;
      ): UInt256 =
  # share the same original storage between multiple
  # versions of account
  acc.original.storage.withValue(slot, val) do:
    return val[]

  # Not in the original values cache - go to the DB unless it's a new account
  if acc.flags * {IsNew, NewlyCreated} == {}:
    result =
      if ledger.balOverlay.isNone():
        let slotKey = ledger.slots.get(slot).valueOr:
          computeSlotKey(slot)
        ledger.fetchSlotChecked(acc.accPath, slotKey)
      else:
        ledger.balOverlay[].getStorage(address, slot).valueOr:
          let slotKey = ledger.slots.get(slot).valueOr:
            computeSlotKey(slot)
          ledger.fetchSlotChecked(acc.accPath, slotKey)

  acc.original.storage[slot] = result

proc storageValue(
    acc: AccountRef;
    address: Address;
    slot: UInt256;
    ledger: LedgerRef;
      ): UInt256 =
  acc.overlayStorage.withValue(slot, val) do:
    return val[]
  do:
    result = acc.originalStorageValue(address, slot, ledger)

proc kill(acc: AccountRef) =
  acc.flags.excl LeafExists
  acc.overlayStorage.reset()
  acc.original.storage.reset()
  acc.original.code.reset()
  acc.code.reset()

proc cachedCode(ledger: LedgerRef, codeHash: Hash32): Opt[CodeBytesRef] =
  ## Code from the cache, or code held back from the database
  let code = ledger.code.get(codeHash)
  if code.isSome() or ledger.heldCode.len == 0:
    return code
  ledger.heldCode.withValue(codeHash, held):
    return Opt.some(held[])
  Opt.none(CodeBytesRef)

func writtenCode(ledger: LedgerRef, codeHash: Hash32): Opt[CodeBytesRef] =
  ## Code set earlier in the block in a save point that is still active. A
  ## reverted write is dropped with its save point.
  var sp = ledger.savePoint
  while sp != nil:
    sp.writtenCode.withValue(codeHash, code):
      return Opt.some(code[])
    sp = sp.parentSavePoint
  Opt.none(CodeBytesRef)

proc persistCode(acc: AccountRef, ledger: LedgerRef) =
  if acc.code.len != 0 and not acc.code.persisted:
    if ledger.holdCode:
      ledger.heldCode[acc.statement.codeHash] = acc.code
      return
    let rc = ledger.txFrame.persistCodeByHash(acc.statement.codeHash, acc.code.bytes())
    if rc.isErr:
      warn logTxt "persistCode()",
       codeHash=acc.statement.codeHash, error=rc.error
    else:
      # If the ledger changes rolled back entirely from the database, the ledger
      # code cache must also be cleared!
      acc.code.persisted = true

template setFatalErrorOrAssert(ledger: LedgerRef, msg: string) =
  ## Handle a failed trie write during persist:
  ## - under stateless execution record a fatal error and stop
  ## - on a full node the state is complete, so assert
  if ledger.stateless:
    ledger.fatalError = Opt.some(msg)
    return
  else:
    raiseAssert msg

template abortOnFatalError*(ledger: LedgerRef) =
  ## Abort the current block if a fatal condition was recorded during execution
  ## or persist, abort meaning:
  ## - a validation error under stateless execution
  ## - otherwise a defect (corrupt database)
  if ledger.fatalError.isSome:
    if ledger.stateless:
      return err(ledger.fatalError.get())
    else:
      raiseAssert ledger.fatalError.get()

proc persistStorage(acc: AccountRef, ledger: LedgerRef): Result[void, string] =
  const info = "persistStorage(): "

  if acc.overlayStorage.len == 0:
    # TODO: remove the storage too if we figure out
    # how to create 'virtual' storage room for each account
    return ok()

  # Save `overlayStorage[]` on database
  let original = acc.original
  for slot, value in acc.overlayStorage:
    original.storage.withValue(slot, v):
      if v[] == value:
        continue # Avoid writing A-B-A updates

    var cached = true
    let slotKey = ledger.slots.get(slot).valueOr:
      cached = false
      let slotKey = computeSlotKey(slot)
      ledger.slots.put(slot, slotKey)
      slotKey

    if value > 0:
      ledger.txFrame.mergeSlot(acc.accPath, slotKey, value).isOkOr:
        return err(info & $$error)

      # move the overlayStorage to originalStorage, related to EIP2200, EIP1283
      original.storage[slot] = value

    else:
      ledger.txFrame.deleteSlot(acc.accPath, slotKey).isOkOr:
        return err(info & $$error)
      original.storage.del(slot)

    if ledger.storeSlotHash and not cached:
      # Write only if it was not cached to avoid writing the same data over and
      # over..
      let
        key = slotKey.slotHashToSlotKey
        rc = ledger.txFrame.put(key.toOpenArray, blobify(slot).data)
      if rc.isErr:
        warn logTxt "persistStorage()", slot, error=($$rc.error)

  acc.overlayStorage.clear()
  ok()

proc makeDirty(ledger: LedgerRef, address: Address, acc: AccountRef, cloneStorage = true): AccountRef =
  if address in ledger.savePoint.cache:
    # it's already in latest savePoint
    if Dirty notin acc.flags:
      ledger.savePoint.dirty[address] = acc
      acc.flags.incl Dirty
    acc
  else:
    let clone = acc.clone(cloneStorage)
    # put a copy into latest savePoint - be careful to do so even if the
    # existing result is already dirty!
    clone.flags.incl Dirty
    ledger.savePoint.cache[address] = clone
    ledger.savePoint.dirty[address] = clone
    clone

template getCodeSizeImpl(ledger: LedgerRef, acc: AccountRef): int =
  if acc.code == nil:
    if acc.statement.codeHash == EMPTY_CODE_HASH:
      return 0
    acc.code = ledger.cachedCode(acc.statement.codeHash).valueOr:
      # On a cache miss, we don't fetch the code - instead, we fetch just the
      # length - should the code itself be needed, it will typically remain
      # cached and easily accessible in the database layer - this is to prevent
      # EXTCODESIZE calls from messing up the code cache and thus causing
      # recomputation of the jump destination table
      var rc = ledger.txFrame.getCodeLenByHash(acc.statement.codeHash)
      if rc.isOk:
        return rc.value
      ledger.writtenCode(acc.statement.codeHash).valueOr:
        # A non-empty code hash whose length is missing from the database: record
        # a fatalError but still return 0 so the async EVM continues.
        warn logTxt "getCodeSize()", codeHash=acc.statement.codeHash, error=rc.error
        ledger.fatalError = Opt.some("getCodeSize(): failed to fetch code length from database")
        return 0

  acc.code.len()

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

# The LedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef): LedgerRef =
  init(x, db, false)

proc isTopLevelClean*(ledger: LedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  ledger.savePoint.parentSavePoint.isNil and ledger.savePoint.dirty.len == 0

proc getStateRoot*(ledger: LedgerRef): Hash32 =
  # make sure all savePoint already committed
  doAssert(ledger.isTopLevelClean())
  # make sure all cache already committed
  ledger.txFrame.getStateRoot().expect("working database")


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
  ledger.savePoint.writtenCode.mergeAndReset(savePoint.writtenCode)

  if ledger.savePoint.parentSavePoint.isNil:
    for codeHash, code in savePoint.pendingCode:
      ledger.code.put(codeHash, code)
    savePoint.pendingCode.clear()
  else:
    ledger.savePoint.pendingCode.mergeAndReset(savePoint.pendingCode)

  savePoint.parentSavePoint = nil # Release memory

proc dispose*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  if savePoint.parentSavePoint != nil:
    ledger.rollback(savePoint)

proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef, storeSlotHash: bool, collectWitness = false, stateless = false): LedgerRef =
  new result
  result.txFrame = db
  result.storeSlotHash = storeSlotHash
  result.code = typeof(result.code).init(codeLruSize)
  result.slots = typeof(result.slots).init(slotsLruSize)
  result.collectWitness = collectWitness
  result.txFrame.aTx.collectWitness = collectWitness
  result.stateless = stateless
  result.blockHashes = typeof(result.blockHashes).init(MAX_PREV_HEADER_DEPTH.int)
  discard result.beginSavePoint

proc reinit*(ledger: LedgerRef, txFrame: CoreDbTxRef) =
  doAssert ledger.isTopLevelClean
  doAssert txFrame.aTx.parent == ledger.txFrame.aTx,
    "reinit txFrame must be a direct child of the ledger's current frame"
  ledger.txFrame = txFrame
  ledger.txFrame.aTx.collectWitness = ledger.collectWitness
  ledger.ripemdSpecial = false
  ledger.fatalError = Opt.none(string)
  ledger.balOverlay = Opt.none(BlockAccessListOverlay)
  ledger.witnessKeys.clear()
  ledger.savePoint.writtenCode.clear()

proc getCodeHash*(ledger: LedgerRef, address: Address): Hash32 =
  let acc = ledger.getAccount(address, false)
  if acc.isNil: EMPTY_ACCOUNT.codeHash
  else: acc.statement.codeHash

proc getBalance*(ledger: LedgerRef, address: Address): UInt256 =
  let acc = ledger.getAccount(address, false)
  if acc.isNil: EMPTY_ACCOUNT.balance
  else: acc.statement.balance

proc getNonce*(ledger: LedgerRef, address: Address): AccountNonce =
  let acc = ledger.getAccount(address, false)
  if acc.isNil: EMPTY_ACCOUNT.nonce
  else: acc.statement.nonce

proc recordCodeRead(ledger: LedgerRef, address: Address, codeHash: Hash32) =
  ## Mark the code as touched in the witness keys if the read is served from
  ## the pre-state: the code is not empty and was not written earlier in this
  ## block.
  ## We overwrite any existing false entry so codeTouched is set to true
  ## even if the account was previously accessed without touching the code.
  if codeHash != EMPTY_CODE_HASH and ledger.writtenCode(codeHash).isNone():
    ledger.witnessKeys[(address, Opt.none(UInt256))] = true

proc getCode*(ledger: LedgerRef,
              address: Address,
              returnHash: static[bool] = false): auto =
  let acc = ledger.getAccount(address, false)

  if ledger.collectWitness and not acc.isNil:
    ledger.recordCodeRead(address, acc.statement.codeHash)

  if acc.isNil:
    when returnHash:
      return (EMPTY_CODE_HASH, CodeBytesRef())
    else:
      return CodeBytesRef()

  if acc.code.isNil:
    acc.code =
      if acc.statement.codeHash != EMPTY_CODE_HASH:
        ledger.cachedCode(acc.statement.codeHash).valueOr:
          var rc = ledger.txFrame.getCodeByHash(acc.statement.codeHash)
          if rc.isErr:
            ledger.writtenCode(acc.statement.codeHash).valueOr:
              # A non-empty code hash with no code in the database: record a fatalError
              # but still return empty code so the async EVM continues.
              warn logTxt "getCode()", codeHash=acc.statement.codeHash, error=rc.error
              ledger.fatalError = Opt.some("getCode(): failed to fetch code from database")
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

proc getOriginalCode*(ledger: LedgerRef, address: Address): CodeBytesRef =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return CodeBytesRef()

  if ledger.collectWitness:
    ledger.recordCodeRead(address, acc.original.statement.codeHash)

  if acc.original.code.isNil:
    acc.original.code =
      if acc.original.statement.codeHash != EMPTY_CODE_HASH:
        ledger.cachedCode(acc.original.statement.codeHash).valueOr:
          var rc = ledger.txFrame.getCodeByHash(acc.original.statement.codeHash)
          if rc.isErr:
            ledger.writtenCode(acc.original.statement.codeHash).valueOr:
              warn logTxt "getCode()", codeHash=acc.original.statement.codeHash, error=rc.error
              CodeBytesRef()
          else:
            let newCode = CodeBytesRef.init(move(rc.value), persisted = true)
            ledger.code.put(acc.original.statement.codeHash, newCode)
            newCode
      else:
        CodeBytesRef()

  acc.original.code

proc getCodeSize*(ledger: LedgerRef, address: Address): int =
  let acc = ledger.getAccount(address, false)

  if ledger.collectWitness and not acc.isNil:
    ledger.recordCodeRead(address, acc.statement.codeHash)

  if acc.isNil:
    return 0
  getCodeSizeImpl(ledger, acc)

proc getCommittedStorage*(ledger: LedgerRef, address: Address, slot: UInt256): UInt256 =
  let acc = ledger.getAccount(address, false)

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  if acc.isNil:
    return
  acc.originalStorageValue(address, slot, ledger)

proc getStorage*(ledger: LedgerRef, address: Address, slot: UInt256): UInt256 =
  let acc = ledger.getAccount(address, false)

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  if acc.isNil:
    return
  acc.storageValue(address, slot, ledger)

proc contractCollision*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return
  acc.statement.nonce != 0 or
    acc.statement.codeHash != EMPTY_CODE_HASH or
      ledger.txFrame.hasStorage(acc.accPath).valueOr(false)

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

proc isAccountAlive*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return false
  if not acc.exists():
    return false
  not acc.isEmpty()

proc originalAccountEmpty*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return true
  acc.original.statement == EMPTY_STATEMENT

proc forcePersist*(ledger: LedgerRef, address: Address) =
  ## Force an account to be written to the database on the next `persist` even
  ## if it was not modified. Loading a pre-state (genesis alloc) must put every
  ## account in the state trie, including empty accounts that no transaction
  ## touches - `getAccount` alone no longer marks such accounts dirty.
  let acc = ledger.getAccount(address)
  if acc.isNil:
    return
  if Dirty notin acc.flags:
    ledger.savePoint.dirty[address] = acc
    acc.flags.incl Dirty

proc setBalance*(ledger: LedgerRef, address: Address, balance: UInt256) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {LeafExists}
  if acc.statement.balance != balance:
    let acc = ledger.makeDirty(address, acc)
    acc.flags.incl StatementChanged
    acc.statement.balance = balance

proc addBalance*(
    ledger: LedgerRef,
    address: Address,
    delta: UInt256,
    checkEmptyAccount: bool = true,
) =
  # EIP161: We must check emptiness for the objects such that the account
  # clearing (0,0,0 objects) can take effect. This is not required for hardforks
  # starting at the merge because by then no empty accounts remain in the state,
  # so callers in that regime can skip the lookup via checkEmptyAccount = false.
  if delta.isZero:
    if checkEmptyAccount:
      let acc = ledger.getAccount(address)
      if acc.isEmpty:
        ledger.makeDirty(address, acc).flags.incl Touched
    elif ledger.collectWitness or ledger.stateless:
      # The reference implementation reads the account even for a zero-value
      # credit (e.g. zero-amount withdrawals, zero-fee coinbase payments), so
      # the address must be part of the execution witness, and stateless
      # execution must be able to fail when the witness lacks its proof.
      discard ledger.getAccount(address, shouldCreate = false)
    return

  let acc = ledger.makeDirty(address, ledger.getAccount(address))
  acc.flags.incl {LeafExists, StatementChanged}
  acc.statement.balance += delta

proc subBalance*(ledger: LedgerRef, address: Address, delta: UInt256) =
  if delta.isZero:
    # This zero delta early exit is important as shown in EIP-4788.
    # If the account is created, it will change the state.
    # But early exit will prevent the account creation.
    # In this case, the SYSTEM_ADDRESS
    return
  let acc = ledger.makeDirty(address, ledger.getAccount(address))
  acc.flags.incl {LeafExists, StatementChanged}
  acc.statement.balance -= delta

proc setNonce*(ledger: LedgerRef, address: Address, nonce: AccountNonce) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {LeafExists}
  if acc.statement.nonce != nonce:
    let acc = ledger.makeDirty(address, acc)
    acc.flags.incl StatementChanged
    acc.statement.nonce = nonce

proc incNonce*(ledger: LedgerRef, address: Address) =
  let acc = ledger.makeDirty(address, ledger.getAccount(address))
  acc.flags.incl {LeafExists, StatementChanged}
  acc.statement.nonce += 1

func peekCode*(ledger: LedgerRef, codeHash: Hash32): Opt[CodeBytesRef] =
  ## Reuse executed code without updating cache membership or recency.
  ledger.code.peek(codeHash)

proc cacheCodeOnCommit*(ledger: LedgerRef, codeHash: Hash32, code: CodeBytesRef) =
  ## Stage successfully executed initcode in the current call frame. A rollback
  ## discards it; committing the outermost savepoint admits it to the code LRU.
  doAssert not ledger.savePoint.parentSavePoint.isNil
  ledger.savePoint.pendingCode[codeHash] = code

proc setCode*(ledger: LedgerRef, address: Address, code: seq[byte]) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {LeafExists}
  let codeHash = keccak256(code)
  if acc.statement.codeHash != codeHash:
    let acc = ledger.makeDirty(address, acc)
    acc.statement.codeHash = codeHash
    # Try to reuse cache entry if it exists, but don't save the code - it's not
    # a given that it will be executed within LRU range
    acc.code = ledger.code.get(codeHash).valueOr(CodeBytesRef.init(code))
    acc.flags.incl {CodeChanged, StatementChanged}
    if (ledger.collectWitness or ledger.stateless) and code.len > 0:
      ledger.savePoint.writtenCode[codeHash] = acc.code

proc setStorage*(ledger: LedgerRef, address: Address, slot, value: UInt256) =
  let acc = ledger.getAccount(address)
  acc.flags.incl {LeafExists}

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  let oldValue = acc.storageValue(address, slot, ledger)
  if oldValue != value:
    let acc = ledger.makeDirty(address, acc)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

proc clearStorage*(ledger: LedgerRef, address: Address) =
  # If there is an existing account with the given address, it is overwritten.
  let acc = ledger.getAccount(address)
  acc.flags.incl {LeafExists, NewlyCreated}

  if ledger.txFrame.hasStorage(acc.accPath).valueOr(false):
    # need to clear the storage from the database first
    let acc = ledger.makeDirty(address, acc, cloneStorage = false)
    # also clear originalStorage cache, otherwise
    # both getStorage and getCommittedStorage will
    # return wrong value
    acc.original.storage.clear()

proc applyBlockAccessList*(ledger: LedgerRef, bal: BlockAccessList, txCount: int) =
  ## Set the block access list's final state for indices up to `txCount` on
  ## the ledger's accounts, for the next persist to write.
  let boundary = txCount + 1
  for accChanges in bal:
    let
      address = accChanges.address
      balancePos = accChanges.balanceChanges.findLastWriteBefore(boundary)
      noncePos = accChanges.nonceChanges.findLastWriteBefore(boundary)
      codePos = accChanges.codeChanges.findLastWriteBefore(boundary)
    var acc: AccountRef

    if balancePos >= 0 or noncePos >= 0 or codePos >= 0:
      acc = ledger.makeDirty(address, ledger.getAccount(address))
      acc.flags.incl LeafExists
      if balancePos >= 0:
        acc.statement.balance = accChanges.balanceChanges[balancePos].postBalance
        acc.flags.incl {StatementChanged}
      if noncePos >= 0:
        acc.statement.nonce = accChanges.nonceChanges[noncePos].newNonce
        acc.flags.incl {StatementChanged}
      if codePos >= 0:
        ledger.setCode(address, accChanges.codeChanges[codePos].newCode)
      if acc.isEmpty:
        acc.flags.incl Touched

    for slotChanges in accChanges.storageChanges:
      let changePos = slotChanges.changes.findLastWriteBefore(boundary)
      if changePos < 0:
        continue
      if acc.isNil:
        acc = ledger.makeDirty(address, ledger.getAccount(address))
        acc.flags.incl LeafExists
      acc.overlayStorage[slotChanges.slot] = slotChanges.changes[changePos].newValue
      acc.flags.incl StorageChanged

proc deleteAccount(ledger: LedgerRef, address: Address) =
  # make sure all savePoints already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  let acc = ledger.getAccount(address)
  if Dirty notin acc.flags:
    ledger.savePoint.dirty[address] = acc
    acc.flags.incl Dirty

  if ClearAccountPreserveBalance in acc.flags:
    if ledger.txFrame.hasStorage(acc.accPath).valueOr(false):
      acc.original.storage.reset()
    else:
      acc.flags.excl StorageChanged

    acc.overlayStorage.reset()
    acc.statement.nonce = 0
    acc.flags.incl StatementChanged

    if acc.statement.codeHash != EMPTY_ACCOUNT.codeHash:
      acc.flags.incl CodeChanged
      acc.statement.codeHash = EMPTY_ACCOUNT.codeHash
      acc.code = CodeBytesRef.init(@[])

    if acc.isEmpty:
      acc.kill()
  else:
    acc.kill()

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

proc selfDestruct8246*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return false

  if NewlyCreated in acc.flags:
    ledger.makeDirty(address, acc).flags.incl ClearAccountPreserveBalance
    ledger.savePoint.selfDestruct.incl address
    true
  else:
    false

proc selfDestructLen*(ledger: LedgerRef): int =
  ledger.savePoint.selfDestruct.len

proc ripemdSpecial*(ledger: LedgerRef) =
  ledger.ripemdSpecial = true

proc clearEmptyAccounts(ledger: LedgerRef) =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  for acc in ledger.savePoint.dirty.values():
    if Touched in acc.flags and acc.isEmpty and acc.exists:
      acc.kill()

  # https://github.com/ethereum/EIPs/issues/716
  if ledger.ripemdSpecial:
    let acc = ledger.getAccount(RIPEMD_ADDR, false)
    if not acc.isNil and acc.isEmpty and acc.exists:
      ledger.savePoint.dirty[RIPEMD_ADDR] = acc
      acc.flags.incl Dirty
      acc.kill()

    ledger.ripemdSpecial = false

template getWitnessKeys*(ledger: LedgerRef): WitnessTable =
  ledger.witnessKeys

proc getCollapsedSiblings*(ledger: LedgerRef): seq[RootedVertexID] =
  ## Collapsed siblings for witness generation. Persist runs per transaction,
  ## so a later insert in the block may restore a collapsed branch. The spec
  ## applies the block's writes at once and only needs the sibling if the
  ## final trie still lacks that branch.
  let db = ledger.txFrame.aTx
  var res: seq[RootedVertexID]
  for (sibling, brVid, brPfxLen) in db.collapsedSiblings:
    let vtx = db.getVtx((sibling.root, brVid))
    if vtx.isValid and vtx.vType in Branches and vtx.pfx.len == int(brPfxLen):
      continue # restored by a later insert
    res.add(sibling)
  res

proc hasUnprovenCollapse*(ledger: LedgerRef): bool =
  ## Stateless only: true if a branch that collapsed onto a child absent from
  ## the witness is still collapsed. The witness then lacks that child.
  let db = ledger.txFrame.aTx
  for rvid in db.unprovenCollapses:
    let vtx = db.getVtx(rvid)
    if vtx.isValid and vtx.vType == BoundaryNode and
        BoundaryNodeRef(vtx).unprovenCollapse:
      return true
  false

template clearWitnessKeys*(ledger: LedgerRef) =
  ledger.witnessKeys.clear()

template clearCollapsedSiblings*(ledger: LedgerRef) =
  ledger.txFrame.aTx.collapsedSiblings.setLen(0)

template clearWrittenCode*(ledger: LedgerRef) =
  ledger.savePoint.writtenCode.clear()

proc getBlockHash*(ledger: LedgerRef, blockNumber: BlockNumber): Hash32 =
  # Range checks must be done earlier, any miss here treated as an error:
  # we record it as a fatalError.
  # The zero hash is still returned so behaviour is otherwise unchanged,
  # in particular the verified proxy's async EVM continues, discovers the
  # number from the cache, fetches it and re-runs.
  ledger.blockHashes.get(blockNumber).valueOr:
    let blockHash = ledger.txFrame.getBlockHash(blockNumber).valueOr:
      ledger.fatalError = Opt.some("Block hash not available for block " & $blockNumber)
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

  for address in ledger.savePoint.selfDestruct:
    ledger.deleteAccount(address)

  if clearEmptyAccount:
    ledger.clearEmptyAccounts()

  for address, acc in ledger.savePoint.dirty: # This is a hotspot in block processing
    if LeafExists in acc.flags:
      if CodeChanged in acc.flags:
        acc.persistCode(ledger)
        acc.original.code = acc.code

      if NewlyCreated in acc.flags or ClearAccountPreserveBalance in acc.flags:
        # TODO https://github.com/status-im/nimbus-eth1/issues/4024
        # When overwriting an account, other clients clear storage - it seems
        # however there's limited spec clarity on this point - in particular,
        # conformance tests pass both with and without this line at the time of
        # writing!
        ledger.txFrame.clearStorage(acc.accPath).expect("can clear storage of account")

      if {IsNew, StatementChanged} * acc.flags != {}:
        # Update account before its storage, in case it's a new account
        # `persistStorage` only works for accounts already in the database
        ledger.txFrame.mergeAccount(acc.accPath, acc.statement).isOkOr:
          ledger.setFatalErrorOrAssert(info & $$error)
        acc.original.statement = acc.statement

      if StorageChanged in acc.flags:
        acc.persistStorage(ledger).isOkOr:
          ledger.setFatalErrorOrAssert(error)

    else:
      ledger.savePoint.cache.del address
      if IsNew notin acc.flags:
        # Only need to delete from the database what was there to begin with
        ledger.txFrame.deleteAccount(acc.accPath).isOkOr:
          if error.error != AccNotFound:
            ledger.setFatalErrorOrAssert(info & $$error)

    acc.flags = acc.flags - resetFlags

  if clearCache:
    # This overwrites the cache from the previous persist, providing a crude LRU
    # scheme with little overhead
    # TODO https://github.com/nim-lang/Nim/issues/23759
    swap(ledger.cache, ledger.savePoint.cache)
    ledger.savePoint.cache.reset()

  ledger.savePoint.dirty.clear()
  ledger.savePoint.selfDestruct.clear()
  ledger.savePoint.accessList.clear() # EIP2929

  if clearWitness:
    ledger.clearWitnessKeys()
    ledger.clearCollapsedSiblings()
    ledger.clearWrittenCode()
    ledger.clearBlockHashesCache()

proc storeHeldCode*(ledger: LedgerRef): Result[void, string] =
  ## Write the code `holdCode` kept back, once its block is accepted.
  for codeHash, code in ledger.heldCode:
    if not code.persisted:
      ledger.txFrame.persistCodeByHash(codeHash, code.bytes()).isOkOr:
        return err("storeHeldCode(): " & error)
      code.persisted = true
  ledger.heldCode.clear()
  ok()

iterator addresses*(ledger: LedgerRef): Address =
  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)
  for address, _ in ledger.savePoint.cache:
    yield address

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
    for k, v in acc.original.storage:
      yield (k, v)

proc getStorageRoot*(ledger: LedgerRef, address: Address): Hash32 =
  # beware that if the account not persisted,
  # the storage root will not be updated
  let acc = ledger.getAccount(address, false)
  if acc.isNil: EMPTY_ROOT_HASH
  else: ledger.txFrame.fetchStorageRoot(acc.accPath).valueOr: EMPTY_ROOT_HASH

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

func copyAccessList*(ledger: LedgerRef): ac_access_list.AccessList =
  ledger.savePoint.accessList

func restoreAccessList*(ledger: LedgerRef, accessList: sink ac_access_list.AccessList) =
  ledger.savePoint.accessList = move(accessList)

func copySelfDestruct*(ledger: LedgerRef): HashSet[Address] =
  ledger.savePoint.selfDestruct

func restoreSelfDestruct*(ledger: LedgerRef, selfDestruct: sink HashSet[Address]) =
  ledger.savePoint.selfDestruct = move(selfDestruct)

proc getLiveAccount*(ledger: LedgerRef, address: Address): AccountRef =
  ledger.getAccount(address, shouldCreate = false)

proc getDirtyAccount*(ledger: LedgerRef, address: Address): AccountRef =
  result = ledger.getAccount(address, shouldCreate = false)
  if result.isNil.not and Dirty notin result.flags:
    return nil

iterator dirtyAccounts*(ledger: LedgerRef): (Address, AccountRef) =
  var sp = ledger.savePoint
  while sp != nil:
    for address, acc in sp.dirty:
      yield (address, acc)
    sp = sp.parentSavePoint

# ------------------------------------------------------------------------------
# Public AccountRef read-only methods
# ------------------------------------------------------------------------------

func originalStatement*(acc: AccountRef): lent CoreDbAccount =
  acc.original.statement

func statement*(acc: AccountRef): lent CoreDbAccount =
  acc.statement

func balanceChanged*(acc: AccountRef): bool =
  acc.statement.balance != acc.original.statement.balance

func nonceChanged*(acc: AccountRef): bool =
  acc.statement.nonce != acc.original.statement.nonce

func codeChanged*(acc: AccountRef): bool =
  CodeChanged in acc.flags

func storageChanged*(acc: AccountRef): bool =
  StorageChanged in acc.flags

func codeChangedToSomething*(acc: AccountRef): bool =
  acc.original.statement.codeHash == EMPTY_CODE_HASH and
    acc.statement.codeHash != EMPTY_CODE_HASH

func slots*(acc: AccountRef): seq[UInt256] =
  for key in acc.overlayStorage.keys:
    result.add key

func storage*(acc: AccountRef, slot: UInt256): UInt256 =
  acc.overlayStorage.getOrDefault(slot)

func originalStorage*(acc: AccountRef, slot: UInt256): UInt256 =
  acc.original.storage.getOrDefault(slot)

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
proc isAccountAlive*(ledger: ReadOnlyLedger, address: Address): bool = isAccountAlive(distinctBase ledger, address)
proc isEmptyAccount*(ledger: ReadOnlyLedger, address: Address): bool = isEmptyAccount(distinctBase ledger, address)
proc getCommittedStorage*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): UInt256 = getCommittedStorage(distinctBase ledger, address, slot)
proc inAccessList*(ledger: ReadOnlyLedger, address: Address): bool = inAccessList(distinctBase ledger, address)
proc inAccessList*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): bool = inAccessList(distinctBase ledger, address, slot)
proc getLiveAccount*(ledger: ReadOnlyLedger, address: Address): AccountRef = getLiveAccount(distinctBase ledger, address)
proc getDirtyAccount*(ledger: ReadOnlyLedger, address: Address): AccountRef = getDirtyAccount(distinctBase ledger, address)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
