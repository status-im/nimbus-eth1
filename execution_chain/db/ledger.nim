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
  ./aristo/[aristo_blobify, aristo_desc]

logScope:
  topics = "ledger"

export code_bytes, core_db.computeAccPath, core_db.computeSlotKey

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
    IsNew
    Dirty
    CodeChanged
    StorageChanged
    StatementChanged
    NewlyCreated # EIP-6780: self destruct only in same transaction
    SelfDestructed
    SelfDestructed8246

  AccountFlags = set[AccountFlag]

  AccountRef* = ref object
    accPath: Hash32

    statement: CoreDbAccount
      ## Account statement in the current save point which may be updated with
      ## respect to originalStatement

    flags: AccountFlags
      ## Modification for what needs to be persisted, ie moved to original on
      ## perstist

    code: CodeBytesRef

    overlayStorage: Table[UInt256, UInt256]
      ## Storage overlay for the current transaction, ie top-level savepoint

    originalStatement: CoreDbAccount
      ## Original statement value at beginning of a transaction - when
      ## values are persisted, this value gets updated meaning that it might
      ## be different from what was loaded from the database

    originalCode: CodeBytesRef

    txStorage: Table[UInt256, UInt256]
      ## Storage cache as read from txFrame - together with `heldStorage`,
      ## this is a view into the pre-transaction storage state of the account.

    heldStorage: Table[UInt256, UInt256]
      ## Storage updates from committed transactions collected for writing
      ## during `persist`.

    writeStatement: bool
      ## `statement` needs writing back to txFrame

    clearStorage: bool
      ## Existing storage should be cleared when updating statement

  JournalKind = enum
    Create # the account was added to the cache
    Balance # statement.balance changed
    Nonce # statement.nonce changed
    Code # statement.codeHash and code changed
    Storage # overlayStorage[slot] changed
    NoStorage # slot was missing
    Flags # only the flags changed (no field)

  JournalEntry = object
    ## Undo record for modifications to `AccountRef`, such that a rollback can
    ## restore accounts to their pre-modification values
    address: Address
    flags: AccountFlags

    case kind: JournalKind
    of Create: discard
    of Balance: balance: UInt256
    of Nonce: nonce: AccountNonce
    of Code:
      codeHash: Hash32
      code: CodeBytesRef
    of Storage:
      slot: UInt256
      value: UInt256
    of NoStorage:
      noslot: UInt256
    of Flags: discard

  LedgerRef* = ref object
    txFrameRef: MaybeOwned[CoreDbTxRef]
    savePoint: LedgerSpRef

    storeSlotHash*: bool
    cache: Table[Address, AccountRef]
      ## Account cache with one one live `AccountRef` per address that's been
      ## touched since the last `persist` that cleared the  cache, typically
      ## once per block.
    cache2: Table[Address, AccountRef]
      ## Second-level account cache, swapped with `cache` on `persist` so the
      ## just-persisted accounts don't have to be re-fetched from the database.
    journal: seq[JournalEntry]
      ## Undo buffer with modifications written but not yet persisted - in case
      ## of a rollback, the journal is played backwards to restore state of
      ## each touched account.
    dirty: Table[Address, AccountRef]
      ## Dirty accounts are those that were modified since the last `persist`
      ## call - if a transaction is persisted, they are either written to the
      ## txFrame or collected in `held` to be batch-saved later.
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

    heldAccounts*: Table[Hash32, AccountRef]
      ## Pending updates to accounts and storage that are collected and
      ## coalesced in memory before writing them to `txFrame`

    heldCode: Table[Hash32, CodeBytesRef]
      ## Code writes collected by `persist` when collecting, flushed to the
      ## database by `storeHeldCode` once the block is accepted.

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
    journalIndex: int
      ## The length of the ledger's undo journal at the moment this save point
      ## began. `rollback` pops the journal back to this index (applying the
      ## entries in reverse); `commit` leaves the entries in place.
    selfDestruct: HashSet[Address]
    accessList: ac_access_list.AccessList
    pendingCode: Table[Hash32, CodeBytesRef]
      ## Executed initcode awaiting successful commit of all enclosing frames.
    writtenCode: Table[Hash32, CodeBytesRef]
      ## Code set in this savepoint, by code hash (stateless execution and
      ## witness collection only). Reads of that hash later in the block are
      ## served from it, so the witness omits that code.

const
  EMPTY_STATEMENT = CoreDbAccount(
    nonce:    EMPTY_ACCOUNT.nonce,
    balance:  EMPTY_ACCOUNT.balance,
    codeHash: EMPTY_ACCOUNT.codeHash,
  )

  MissingNodeErrors = {HikeBranchUnresolvedEdge, HikeDanglingEdge}
    ## A trie node this read's path needs is missing locally, so unlike a
    ## proof of absence we can't tell if the account/slot exists. Covers an
    ## incomplete witness (stateless) or a not-yet-fetched trie (verified proxy).

template txFrame*(ledger: LedgerRef): CoreDbTxRef =
  ledger.txFrameRef.get()

func `txFrame=`*(ledger: LedgerRef, txFrame: CoreDbTxRef) =
  ledger.txFrameRef.own(txFrame)

func borrowTxFrame*(ledger: LedgerRef, txFrame: CoreDbTxRef) =
  ledger.txFrameRef.borrow(txFrame)

template addJournal(ledger: LedgerRef, entry: JournalEntry) =
  ledger.journal.add entry

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
  if overlayAcc.codeHash.isSome():
    acc.statement.codeHash = overlayAcc.codeHash[]

func isEmpty(statement: CoreDbAccount): bool =
  # Check nonce first since it's the fastest to compare
  statement.nonce == 0 and statement.balance.isZero and
    statement.codeHash == EMPTY_CODE_HASH

proc slotKey(ledger: LedgerRef, slot: UInt256): Hash32 =
  ledger.slots.get(slot).valueOr:
    let slotKey = computeSlotKey(slot)
    ledger.slots.put(slot, slotKey)

    if ledger.storeSlotHash:
      # Write only if it was not cached to avoid writing the same data over and
      # over..
      let key = slotKey.slotHashToSlotKey
      ledger.txFrame.put(key.toOpenArray, blobify(slot).data).isOkOr:
        warn "Put slot key failed", slot, error = ($$error)

    slotKey

proc hasStorage(ledger: LedgerRef, acc: AccountRef): bool =
  ## Like `txFrame.hasStorage`, but accounts for the pending writes of the
  ## account collected by `persist`.
  for v in acc.heldStorage.values():
    if not v.isZero():
      return true

  if acc.clearStorage:
    return false # heldStorage is empty, so the account has no storage

  ledger.txFrame.hasStorage(acc.accPath).valueOr(false)

proc getAccount(ledger: LedgerRef, address: Address, shouldCreate = true): AccountRef =
  if ledger.collectWitness:
    let lookupKey = (address, Opt.none(UInt256))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  # search the account cache shared by all active save points
  result = ledger.cache.getOrDefault(address)
  if not result.isNil:
    return

  if ledger.cache2.pop(address, result):
    # Check second-level cache
    ledger.cache[address] = result
    ledger.addJournal JournalEntry(kind: Create, address: address, flags: result.flags)
    return

  var clearStorage = false
  let accPath = address.computeAccPath

  ledger.heldAccounts.withValue(accPath, acc):
    doAssert acc[].isNil, "only removals are held without being cached"

    # Make sure that if we write the account, we would write it afresh without
    # the storage that would have happened with a delete first.
    clearStorage = true

  do:
    # The account is not in the pending changes collected by `persist` - next
    # stop is the database
    let rc = ledger.txFrame.fetchAccount accPath

    if rc.isErr and rc.error.isAristo and rc.error.aErr in MissingNodeErrors:
      # Record a fatalError: never assert here, always fall through to the normal
      # "not found" path. The async EVM (verified proxy) relies on that.
      warn "Witness missing an internal trie node required to resolve account",
        address, error = ($$rc.error)
      ledger.fatalError = Opt.some(
        "getAccount(): witness missing an internal trie node required to resolve account " & $address)

    if rc.isOk:
      # Acc found in the database
      result = AccountRef(
        accPath: accPath,
        statement: rc.value,
        originalStatement: rc.value,
        clearStorage: clearStorage,
      )

  if ledger.balOverlay.isSome() and ledger.balOverlay[].hasAccount(address):
    # Acc found in the BAL overlay
    if result.isNil():
      result = AccountRef(
        accPath: accPath,
        statement: EMPTY_STATEMENT,
        originalStatement: EMPTY_STATEMENT,
        clearStorage: clearStorage,
      )
    ledger.applyOverlay(address, result)
    # If the account from the overlay is empty, it was self destructed
    # and so we treat it as such.
    if result.statement.isEmpty():
      result = nil
    else:
      result.originalStatement = result.statement
      result.originalCode = result.code

  if result.isNil:
    if not shouldCreate:
      return

    result = AccountRef(
      accPath: accPath,
      statement: EMPTY_STATEMENT,
      flags: {IsNew},
      originalStatement: EMPTY_STATEMENT,
      clearStorage: clearStorage,
    )

  # cache the account
  ledger.cache[address] = result
  ledger.addJournal JournalEntry(kind: Create, address: address, flags: result.flags)

template fetchSlotChecked(ledger: LedgerRef, accPath: Hash32, slot: UInt256): UInt256 =
  ## Like `fetchSlot`, but a witness gap on the slot's path is a fatal
  ## condition rather than a silent `0`. Records the condition without an
  ## early return, same reasoning as `getAccount`.
  let slotKey = ledger.slots.get(slot).valueOr:
    computeSlotKey(slot)

  let slotRc = ledger.txFrame.fetchSlot(accPath, slotKey)
  if slotRc.isErr:
    if slotRc.error.isAristo and slotRc.error.aErr in MissingNodeErrors:
      warn "fetchSlot failed", error = ($$slotRc.error)
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
  if acc.flags * {IsNew, NewlyCreated} != {}:
    # New and newly created accounts have no original storage, so we can skip
    # the database lookup / caching
    return 0'u256

  acc.heldStorage.withValue(slot, val):
    return val[]

  # When `clearStorage` is set, all existing diffs are cleared so the the diffs
  # above must have come after setting clearStorage (which is why we check them
  # first)
  if acc.clearStorage:
    return 0'u256

  acc.txStorage.withValue(slot, val):
    return val[]

  result =
    if ledger.balOverlay.isNone():
      ledger.fetchSlotChecked(acc.accPath, slot)
    else:
      ledger.balOverlay[].getStorage(address, slot).valueOr:
        ledger.fetchSlotChecked(acc.accPath, slot)

  acc.txStorage[slot] = result

proc storageValue(
    acc: AccountRef;
    address: Address;
    slot: UInt256;
    ledger: LedgerRef;
      ): UInt256 =
  acc.overlayStorage.withValue(slot, val):
    return val[]
  acc.originalStorageValue(address, slot, ledger)

proc destruct(acc: AccountRef) =
  acc.flags.excl {CodeChanged, StorageChanged, StatementChanged}
  acc.overlayStorage.reset() # free memory
  acc.txStorage.reset()
  acc.originalCode.reset()
  acc.code.reset()

func writtenCode(ledger: LedgerRef, codeHash: Hash32): Opt[CodeBytesRef] =
  ## Code set earlier in the block in a save point that is still active. A
  ## reverted write is dropped with its save point.
  var sp = ledger.savePoint
  while sp != nil:
    sp.writtenCode.withValue(codeHash, code):
      return Opt.some(code[])
    sp = sp.parentSavePoint
  Opt.none(CodeBytesRef)

proc cachedCode(ledger: LedgerRef, codeHash: Hash32): Opt[CodeBytesRef] =
  ## Code from the cache, or code held back from the database
  let code = ledger.code.get(codeHash) or ledger.writtenCode(codeHash)
  if code.isSome():
    return code
  ledger.heldCode.withValue(codeHash, held):
    return Opt.some(held[])
  Opt.none(CodeBytesRef)

proc persistCode(acc: AccountRef, ledger: LedgerRef, hold: bool) =
  if acc.code.len != 0 and not acc.code.persisted:
    if hold:
      # Defer the write until the block is accepted, see `storeHeldCode`
      ledger.heldCode[acc.statement.codeHash] = acc.code
      return
    let rc = ledger.txFrame.persistCodeByHash(acc.statement.codeHash, acc.code.bytes())
    if rc.isErr:
      warn "persistCode failed",
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

proc collectStorage(acc: AccountRef) =
  ## Merge the account's pending storage writes into the block's held writes
  if acc.heldStorage.len == 0:
    acc.heldStorage = move acc.overlayStorage
  else:
    for slot, value in acc.overlayStorage:
      acc.heldStorage[slot] = value
    acc.overlayStorage.reset()

proc persistStorage(
    ledger: LedgerRef,
    accPath: Hash32,
    hasStorage: bool,
    original: var Table[UInt256, UInt256],
    overlay: Table[UInt256, UInt256],
): Result[void, string] =
  ## Persist the changes from `overlay` to txFrame, updating `original` with
  ## the changes on the fly
  const info = "persistStorage(): "

  template updated(slot, value): bool =
    if not hasStorage:
      if not value.isZero:
        original[slot] = value
        true
      else:
        false
    else:
      var same = false
      original.withValue(slot, v):
        same = v[] == value
        if not same:
          v[] = value
      do:
        original[slot] = value
      not same

  if overlay.len > 1:
    var updates = newSeqOfCap[(Hash32, UInt256)](overlay.len())

    for slot, value in overlay:
      if updated(slot, value):
        updates.add (ledger.slotKey(slot), value)

    if updates.len > 0:
      ledger.txFrame.mergeSlots(accPath, updates).isOkOr:
        return err(info & $$error)
  else: # Avoid seq allocation for single-slot update
    for slot, value in overlay: # Only one iteration!
      if updated(slot, value):
        let slotKey = ledger.slotKey(slot)
        ledger.txFrame.mergeSlots(accPath, (slotKey, value)).isOkOr:
          return err(info & $$error)
      break

  ok()

proc persistHeld(ledger: LedgerRef) =
  ## Write the pending writes collected by `persist` to the frame.
  for accPath, acc in ledger.heldAccounts:
    if acc.isNil: # deleted
      ledger.txFrame.deleteAccount(accPath).isOkOr:
        if error.error != AccNotFound:
          ledger.setFatalErrorOrAssert($$error)
    else:
      # Conservatively, we might have storage unless we're clearing the account
      let hasStorage = not acc.clearStorage

      if acc.writeStatement or acc.clearStorage:
        ledger.txFrame.mergeAccount(
          accPath, acc.originalStatement, acc.clearStorage
        ).isOkOr:
          ledger.setFatalErrorOrAssert($$error)
        # Both are one-shot flags: `writeStatement` marks a statement to write
        # and `clearStorage` marks the pre-block storage as cleared (a newly
        # created or deleted account). They are consumed here and must not leak
        # into the next block, where the account is served from the warm cache.
        acc.writeStatement = false
        acc.clearStorage = false

      ledger.persistStorage(
        accPath, hasStorage, acc.txStorage, acc.heldStorage
      ).isOkOr:
        ledger.setFatalErrorOrAssert(error)

      acc.heldStorage.reset()

  ledger.heldAccounts.reset()

proc makeDirty(ledger: LedgerRef, address: Address, acc: AccountRef): AccountRef =
  # Collect the accounts to be processed by persist in a separate set since
  # only a small part of the cached (per block) records actually get updated.
  if Dirty notin acc.flags:
    ledger.dirty[address] = acc
    acc.flags.incl Dirty
  acc

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

# The LedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef): LedgerRef =
  init(x, db, false)

proc isTopLevelClean*(ledger: LedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  ledger.savePoint.parentSavePoint.isNil and ledger.dirty.len == 0 and
    ledger.heldAccounts.len == 0

proc getStateRoot*(ledger: LedgerRef): Hash32 =
  # make sure all savePoint already committed
  doAssert(ledger.isTopLevelClean())
  # make sure all cache already committed
  ledger.txFrame.getStateRoot().expect("working database")


proc beginSavePoint*(ledger: LedgerRef): LedgerSpRef =
  let savePoint = LedgerSpRef(
    parentSavePoint: ledger.savePoint,
    journalIndex: ledger.journal.len,
  )

  ledger.savePoint = savePoint

  savePoint

proc rollback*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ledger.savePoint == savePoint and not savePoint.parentSavePoint.isNil

  # Pop the undo journal back to this save point's index, applying the entries
  # in reverse: restore each changed field and delete the accounts that were
  # created. The cache lives on the ledger, so the restored state is visible
  # immediately. Field entries are always replayed before the `Create` entry
  # for the same account (which is earlier in the journal), so the account is
  # still cached when its fields are restored.
  while ledger.journal.len > savePoint.journalIndex:
    let entry = ledger.journal.pop()
    # The account is always cached for a non-`Create` entry: its `Create` entry
    # (if any) is earlier in the journal and is replayed after this one.
    let acc =
      if entry.kind == Create:
        nil
      else:
        let a = ledger.cache.getOrDefault(entry.address)
        doAssert a != nil, "journal entry for an account missing from the cache"
        a

    if Dirty notin entry.flags:
      ledger.dirty.del(entry.address)

    case entry.kind:
    of Create:
      ledger.cache.del(entry.address)
    of Balance:
      acc.statement.balance = entry.balance
      acc.flags = entry.flags
    of Nonce:
      acc.statement.nonce = entry.nonce
      acc.flags = entry.flags
    of Code:
      acc.statement.codeHash = entry.codeHash
      acc.code = entry.code
      acc.flags = entry.flags
    of Storage:
      acc.overlayStorage[entry.slot] = entry.value
      acc.flags = entry.flags
    of NoStorage:
      acc.overlayStorage.del(entry.noslot)
      acc.flags = entry.flags
    of Flags:
      acc.flags = entry.flags

  ledger.savePoint = savePoint.parentSavePoint

  reset(savePoint[]) # Release memory

proc commit*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ledger.savePoint == savePoint and not savePoint.parentSavePoint.isNil

  ledger.savePoint = savePoint.parentSavePoint
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
  # Clear memory associated with the given savepoint - ledger cannot be used
  # after this call, except to dispose of more savepoints
  ledger.savePoint = savePoint.parentSavePoint
  reset(savePoint[])
  ledger.dirty.reset()
  ledger.cache.reset()
  ledger.cache2.reset()
  ledger.journal.reset()

proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef, storeSlotHash: bool, collectWitness = false, stateless = false): LedgerRef =
  new result
  result.txFrame = db
  result.storeSlotHash = storeSlotHash
  result.code = typeof(result.code).init(codeLruSize)
  result.slots = typeof(result.slots).init(slotsLruSize)
  result.collectWitness = collectWitness
  result.txFrame.collectWitness = collectWitness
  result.stateless = stateless
  result.blockHashes = typeof(result.blockHashes).init(MAX_PREV_HEADER_DEPTH.int)
  discard result.beginSavePoint

proc reinit*(ledger: LedgerRef, txFrame: CoreDbTxRef) =
  doAssert ledger.isTopLevelClean
  doAssert txFrame.isChildOf(ledger.txFrame),
    "reinit txFrame must be a direct child of the ledger's current frame"
  ledger.txFrame = txFrame
  ledger.txFrame.collectWitness = ledger.collectWitness
  ledger.fatalError = Opt.none(string)
  ledger.balOverlay = Opt.none(BlockAccessListOverlay)
  ledger.heldAccounts.reset()
  ledger.heldCode.reset()
  ledger.witnessKeys.clear()
  ledger.savePoint.writtenCode.clear()

proc getCodeHash*(ledger: LedgerRef, address: Address): Hash32 =
  const noCodeHash = default(Hash32)
  let acc = ledger.getAccount(address, false)
  if acc.isNil() or acc.statement.isEmpty(): noCodeHash
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
  if ledger.collectWitness and ledger.writtenCode(codeHash).isNone():
    ledger.witnessKeys[(address, Opt.none(UInt256))] = true

proc ensureCodeLoaded(ledger: LedgerRef, acc: AccountRef) =
  if acc.code.isNil:
    acc.code = ledger.cachedCode(acc.statement.codeHash).valueOr:
      var rc = ledger.txFrame.getCodeByHash(acc.statement.codeHash)
      if rc.isErr:
        # A non-empty code hash with no code in the database: record a fatalError
        # but still return empty code so the async EVM continues.
        warn "getCodeByHash failed", codeHash = acc.statement.codeHash, error = rc.error
        ledger.fatalError = Opt.some("getCode(): failed to fetch code from database")
        CodeBytesRef()
      else:
        let newCode = CodeBytesRef.init(move(rc.value), persisted = true)
        ledger.code.put(acc.statement.codeHash, newCode)
        newCode

proc getCode*(ledger: LedgerRef,
              address: Address,
              returnHash: static[bool] = false): auto =
  let acc = ledger.getAccount(address, false)
  if acc.isNil or acc.statement.codeHash == EMPTY_CODE_HASH:
    when returnHash:
      return (EMPTY_CODE_HASH, CodeBytesRef())
    else:
      return CodeBytesRef()

  ledger.recordCodeRead(address, acc.statement.codeHash)
  ledger.ensureCodeLoaded(acc)

  when returnHash:
    (acc.statement.codeHash, acc.code)
  else:
    acc.code

proc getOriginalCode*(ledger: LedgerRef, address: Address): CodeBytesRef =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return CodeBytesRef()

  let codeHash = acc.originalStatement.codeHash
  if codeHash == EMPTY_CODE_HASH:
    return CodeBytesRef()

  ledger.recordCodeRead(address, codeHash)

  if acc.originalCode.isNil:
    acc.originalCode = ledger.cachedCode(codeHash).valueOr:
      var rc = ledger.txFrame.getCodeByHash(codeHash)
      if rc.isErr:
        warn "getCodeByHash failed", codeHash, error = rc.error
        CodeBytesRef()
      else:
        let newCode = CodeBytesRef.init(move(rc.value), persisted = true)
        ledger.code.put(codeHash, newCode)
        newCode

  acc.originalCode

proc getCodeSize*(ledger: LedgerRef, address: Address): int =
  let acc = ledger.getAccount(address, false)

  if acc.isNil or acc.statement.codeHash == EMPTY_CODE_HASH:
    return 0

  ledger.recordCodeRead(address, acc.statement.codeHash)

  if acc.code.isNil:
    acc.code = ledger.cachedCode(acc.statement.codeHash).valueOr:
      # On a cache miss, we don't fetch the code - instead, we fetch just the
      # length - should the code itself be needed, it will typically remain
      # cached and easily accessible in the database layer - this is to prevent
      # EXTCODESIZE calls from messing up the code cache and thus causing
      # recomputation of the jump destination table
      return ledger.txFrame.getCodeLenByHash(acc.statement.codeHash).valueOr:
        # A non-empty code hash whose length is missing from the database: record
        # a fatalError but still return 0 so the async EVM continues.
        warn "getCodeLenByHash failed", codeHash=acc.statement.codeHash, error
        ledger.fatalError = Opt.some("getCodeSize(): failed to fetch code length from database")
        return 0

  acc.code.len()

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
    ledger.hasStorage(acc)

proc accountExists*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  acc.isNil.not

proc isAccountEmpty*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return true
  acc.statement.isEmpty()

proc originalAccountEmpty*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return true
  acc.originalStatement.isEmpty()

proc touch*(ledger: LedgerRef, address: Address) =
  ## Force an account to be written to the database on the next `persist` even
  ## if it was not modified. Loading a pre-state (genesis alloc) must put every
  ## account in the state trie, including empty accounts that no transaction
  ## touches - `getAccount` alone no longer marks such accounts dirty.
  let acc = ledger.getAccount(address)
  if acc.isNil:
    return
  if Dirty notin acc.flags:
    ledger.dirty[address] = acc
    acc.flags.incl Dirty

proc canAdoptCode*(ledger: LedgerRef, address: Address): Opt[Hash32] =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return Opt.none(Hash32)
  if NewlyCreated in acc.flags:
    return Opt.none(Hash32)
  if acc.statement.codeHash == EMPTY_CODE_HASH:
    return Opt.none(Hash32)

  ledger.recordCodeRead(address, acc.statement.codeHash)
  ledger.ensureCodeLoaded(acc)

  if acc.code.len == 0:
    # The check above for EMPTY_CODE_HASH should handle
    # zero length. This is an extra check.
    return Opt.none(Hash32)
  if acc.code.bytes[0] == 0xEF:
    return Opt.none(Hash32)
  ok(acc.statement.codeHash)

proc setBalance*(ledger: LedgerRef, address: Address, balance: UInt256) =
  let acc = ledger.getAccount(address)
  if acc.statement.balance != balance:
    ledger.addJournal JournalEntry(
      kind: Balance, address: address, balance: acc.statement.balance, flags: acc.flags
    )
    let acc = ledger.makeDirty(address, acc)
    acc.flags.incl StatementChanged
    acc.statement.balance = balance

proc addBalance*(
    ledger: LedgerRef, address: Address, delta: UInt256, checkEmptyAccount: bool
) =
  if delta.isZero:
    if checkEmptyAccount:
      let acc = ledger.getAccount(address)
      if acc.statement.isEmpty():
        ledger.addJournal JournalEntry(kind: Flags, address: address, flags: acc.flags)
        discard ledger.makeDirty(address, acc)
    elif ledger.collectWitness or ledger.stateless:
      # The reference implementation reads the account even for a zero-value
      # credit (e.g. zero-amount withdrawals, zero-fee coinbase payments), so
      # the address must be part of the execution witness, and stateless
      # execution must be able to fail when the witness lacks its proof.
      discard ledger.getAccount(address, shouldCreate = false)
    return

  let acc = ledger.getAccount(address)
  ledger.addJournal JournalEntry(
    kind: Balance, address: address, balance: acc.statement.balance, flags: acc.flags
  )
  discard ledger.makeDirty(address, acc)
  acc.flags.incl StatementChanged
  acc.statement.balance += delta

proc subBalance*(ledger: LedgerRef, address: Address, delta: UInt256) =
  if delta.isZero:
    # This zero delta early exit is important as shown in EIP-4788.
    # If the account is created, it will change the state.
    # But early exit will prevent the account creation.
    # In this case, the SYSTEM_ADDRESS
    return
  let acc = ledger.getAccount(address)
  ledger.addJournal JournalEntry(
    kind: Balance, address: address, balance: acc.statement.balance, flags: acc.flags
  )
  discard ledger.makeDirty(address, acc)
  acc.flags.incl StatementChanged
  acc.statement.balance -= delta

proc setNonce*(ledger: LedgerRef, address: Address, nonce: AccountNonce) =
  let acc = ledger.getAccount(address)
  if acc.statement.nonce != nonce:
    ledger.addJournal JournalEntry(
      kind: Nonce, address: address, nonce: acc.statement.nonce, flags: acc.flags
    )
    let acc = ledger.makeDirty(address, acc)
    acc.flags.incl StatementChanged
    acc.statement.nonce = nonce

proc incNonce*(ledger: LedgerRef, address: Address) =
  let acc = ledger.getAccount(address)
  ledger.addJournal JournalEntry(
    kind: Nonce, address: address, nonce: acc.statement.nonce, flags: acc.flags
  )
  discard ledger.makeDirty(address, acc)
  acc.flags.incl StatementChanged
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
  let codeHash = keccak256(code)
  if acc.statement.codeHash != codeHash:
    ledger.addJournal JournalEntry(
      kind: Code,
      address: address,
      codeHash: acc.statement.codeHash,
      code: acc.code,
      flags: acc.flags,
    )
    let acc = ledger.makeDirty(address, acc)
    acc.statement.codeHash = codeHash
    acc.flags.incl StatementChanged

    if code.len == 0:
      acc.flags.excl CodeChanged
      acc.code = nil # EMPTY_CODE_HASH
      return

    # Try to reuse cache entry if it exists, but don't save the code - it's not
    # a given that it will be executed within LRU range
    acc.flags.incl CodeChanged
    acc.code = ledger.cachedCode(codeHash).valueOr(CodeBytesRef.init(code))
    if (ledger.collectWitness or ledger.stateless):
      ledger.savePoint.writtenCode[codeHash] = acc.code

proc adoptCode*(ledger: LedgerRef, address: Address, codeHash: Hash32) =
  let acc = ledger.getAccount(address)
  if acc.statement.codeHash != codeHash:
    let acc = ledger.makeDirty(address, acc)
    acc.statement.codeHash = codeHash
    acc.flags.incl StatementChanged
    acc.code = nil

proc setStorage*(ledger: LedgerRef, address: Address, slot, value: UInt256) =
  let acc = ledger.getAccount(address)

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  let oldValue = acc.storageValue(address, slot, ledger)
  if oldValue != value:
    acc.overlayStorage.withValue(slot, v):
      ledger.addJournal JournalEntry(
        kind: Storage, address: address, slot: slot, value: v[], flags: acc.flags
      )
    do:
      ledger.addJournal JournalEntry(
        kind: NoStorage, address: address, noslot: slot, flags: acc.flags
      )
    let acc = ledger.makeDirty(address, acc)
    acc.overlayStorage[slot] = value
    acc.flags.incl StorageChanged

func collectClearStorage(acc: AccountRef) =
  ## Clear the account's storage on the next `persist` even if it was not
  ## modified. This is used to implement EIP-161's "clear empty accounts" rule.
  acc.clearStorage = true
  acc.heldStorage.reset()
  acc.txStorage.reset()

proc clearStorage*(ledger: LedgerRef, address: Address) =
  # If there is an existing account with the given address, its storage will get
  # overwritten on persist

  let acc = ledger.getAccount(address)
  ledger.addJournal JournalEntry(kind: Flags, address: address, flags: acc.flags)
  discard ledger.makeDirty(address, acc)
  acc.flags.incl NewlyCreated

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
      acc = ledger.getAccount(address)
      if balancePos >= 0:
        ledger.addJournal JournalEntry(
          kind: Balance,
          address: address,
          balance: acc.statement.balance,
          flags: acc.flags,
        )
      if noncePos >= 0:
        ledger.addJournal JournalEntry(
          kind: Nonce, address: address, nonce: acc.statement.nonce, flags: acc.flags
        )
      if codePos >= 0:
        ledger.addJournal JournalEntry(
          kind: Code,
          address: address,
          codeHash: acc.statement.codeHash,
          code: acc.code,
          flags: acc.flags,
        )

      acc = ledger.makeDirty(address, acc)
      if balancePos >= 0:
        acc.statement.balance = accChanges.balanceChanges[balancePos].postBalance
        acc.flags.incl {StatementChanged}
      if noncePos >= 0:
        acc.statement.nonce = accChanges.nonceChanges[noncePos].newNonce
        acc.flags.incl {StatementChanged}
      if codePos >= 0:
        ledger.setCode(address, accChanges.codeChanges[codePos].newCode)

    for slotChanges in accChanges.storageChanges:
      let changePos = slotChanges.changes.findLastWriteBefore(boundary)
      if changePos < 0:
        continue
      if acc.isNil:
        acc = ledger.getAccount(address)

      acc.overlayStorage.withValue(slotChanges.slot, v):
        ledger.addJournal JournalEntry(
          kind: Storage,
          address: address,
          slot: slotChanges.slot,
          value: v[],
          flags: acc.flags,
        )
      do:
        ledger.addJournal JournalEntry(
          kind: NoStorage, address: address, noslot: slotChanges.slot, flags: acc.flags
        )

      acc = ledger.makeDirty(address, acc)
      acc.overlayStorage[slotChanges.slot] = slotChanges.changes[changePos].newValue
      acc.flags.incl StorageChanged

proc selfDestruct*(ledger: LedgerRef, address: Address) =
  # SELFDESTRUCT: burn balance now and remove account later
  var acc = ledger.getAccount(address, false)
  if acc.isNil:
    return

  ledger.addJournal JournalEntry(
    kind: Balance, address: address, balance: acc.statement.balance, flags: acc.flags
  )
  acc = ledger.makeDirty(address, acc)
  acc.statement.balance = 0'u256
  acc.flags.incl SelfDestructed
  ledger.savePoint.selfDestruct.incl address

proc selfDestruct6780*(ledger: LedgerRef, address: Address): bool =
  # EIP-6780: SELFDESTRUCT, same but only if it's a newly created contract
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return false

  if NewlyCreated in acc.flags:
    ledger.addJournal JournalEntry(
      kind: Balance, address: address, balance: acc.statement.balance, flags: acc.flags
    )
    let acc = ledger.makeDirty(address, acc)
    acc.statement.balance = 0'u256
    acc.flags.incl SelfDestructed
    ledger.savePoint.selfDestruct.incl address

    true
  else:
    false

proc selfDestruct8246*(ledger: LedgerRef, address: Address): bool =
  # EIP-8246: SELFDESTRUCT same but keep the balance
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return false

  if NewlyCreated in acc.flags:
    ledger.addJournal JournalEntry(kind: Flags, address: address, flags: acc.flags)
    let acc = ledger.makeDirty(address, acc)
    acc.flags.incl SelfDestructed8246
    ledger.savePoint.selfDestruct.incl address

    true
  else:
    false

proc selfDestructLen*(ledger: LedgerRef): int =
  ledger.savePoint.selfDestruct.len

proc ripemdSpecial*(ledger: LedgerRef) =
  let acc = ledger.getAccount(RIPEMD_ADDR, false)
  if not acc.isNil and acc.statement.isEmpty():
    ledger.addJournal JournalEntry(kind: Flags, address: RIPEMD_ADDR, flags: acc.flags)
    discard ledger.makeDirty(RIPEMD_ADDR, acc)

template getWitnessKeys*(ledger: LedgerRef): WitnessTable =
  ledger.witnessKeys

template clearWitnessKeys*(ledger: LedgerRef) =
  ledger.witnessKeys.clear()

template clearCollapsedSiblings*(ledger: LedgerRef) =
  ledger.txFrame.clearCollapsedSiblings()

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

proc persist*(
    ledger: LedgerRef,
    clearEmptyAccounts: bool,
    clearCache = false,
    clearWitness = false,
    hold = false,
) =
  const info = "persist(): "

  # make sure all savePoint already committed
  doAssert(ledger.savePoint.parentSavePoint.isNil)

  let useDiff = hold or ledger.heldAccounts.len > 0

  for address, acc in ledger.dirty: # This is a hotspot in block processing
    # Self-destructed accounts must retain their values throughout transaction
    # processing and only kill/clear themselves at the end
    let exists =
      if SelfDestructed8246 in acc.flags:
        if acc.statement.balance.isZero():
          acc.destruct()
          false
        else:
          acc.overlayStorage.reset()
          acc.statement.codeHash = EMPTY_CODE_HASH
          acc.statement.nonce = 0
          acc.code = nil
          # Make sure storage gets cleared
          doAssert NewlyCreated in acc.flags,
            "SELFDESTRUCT only valid in newly created contracts"
          acc.flags.incl {StatementChanged}
          acc.flags.excl {CodeChanged, StorageChanged}
          true
      elif (SelfDestructed in acc.flags) or
        (clearEmptyAccounts and acc.statement.isEmpty()):
        # EIP-161: empty accounts get removed from the trie
        # EIP-8246: before this, self-destructed balances are burned
        acc.destruct()
        false
      else:
        true

    if exists:
      if CodeChanged in acc.flags:
        acc.persistCode(ledger, useDiff)
        acc.originalCode = acc.code

      let clearStorage = {IsNew, NewlyCreated} * acc.flags != {}
      if clearStorage:
        if useDiff:
          ledger.heldAccounts[acc.accPath] = acc
          acc.collectClearStorage()
        else:
          acc.txStorage.reset()

      if {IsNew, StatementChanged} * acc.flags != {} or clearStorage:
        # Update account before its storage, in case it's a new account
        # `persistStorage` only works for accounts already in the database
        if useDiff:
          ledger.heldAccounts[acc.accPath] = acc
          acc.writeStatement = true
        else:
          ledger.txFrame.mergeAccount(acc.accPath, acc.statement, clearStorage).isOkOr:
            ledger.setFatalErrorOrAssert(info & $$error)
        acc.originalStatement = acc.statement

      if StorageChanged in acc.flags:
        if useDiff:
          ledger.heldAccounts[acc.accPath] = acc
          acc.collectStorage()
        else:
          let hasStorage = not clearStorage
          ledger.persistStorage(
            acc.accPath, hasStorage, acc.txStorage, acc.overlayStorage
          ).isOkOr:
            ledger.setFatalErrorOrAssert(error)
          acc.overlayStorage.reset()

      acc.flags.reset()
    else:
      ledger.cache.del address
      if IsNew notin acc.flags:
        # Only need to delete from the database what was there to begin with
        if useDiff:
          ledger.heldAccounts[acc.accPath] = nil
        else:
          ledger.txFrame.deleteAccount(acc.accPath).isOkOr:
            if error.error != AccNotFound:
              ledger.setFatalErrorOrAssert(info & $$error)

  if clearCache:
    # This overwrites the cache from the previous persist, providing a crude LRU
    # scheme with little overhead
    # TODO https://github.com/nim-lang/Nim/issues/23759
    swap(ledger.cache, ledger.cache2)
    ledger.cache.reset()

  ledger.dirty.reset()
  # The top-level save point is never rolled back, so its journal entries are
  # permanent (already committed to the frame): discard them.
  ledger.journal.setLen(0)
  ledger.savePoint.selfDestruct.clear()
  ledger.savePoint.accessList.clear() # EIP2929

  if clearWitness:
    ledger.clearWitnessKeys()
    ledger.clearCollapsedSiblings()
    ledger.clearWrittenCode()
    ledger.clearBlockHashesCache()

  if not hold:
    ledger.persistHeld()

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
  for address in ledger.cache.keys():
    yield address

iterator storage*(
    ledger: LedgerRef;
    address: Address;
      ): (UInt256, UInt256) =
  # beware that if the account not persisted,
  # the storage root will not be updated
  doAssert ledger.heldAccounts.len == 0, "cannot iterate while block writes are pending"
  for (slotHash, value) in ledger.txFrame.slotPairs address.computeAccPath:
    let rc = ledger.txFrame.get(slotHashToSlotKey(slotHash).toOpenArray)
    if rc.isErr:
      warn "get storage failed", slotHash, error=($$rc.error)
      continue
    let r = deblobify(rc.value, UInt256)
    if r.isErr:
      warn "storage deblobify failed", slotHash, msg=r.error
      continue
    yield (r.value, value)

iterator cachedStorage*(ledger: LedgerRef, address: Address): (UInt256, UInt256) =
  let acc = ledger.getAccount(address, false)
  if not acc.isNil:
    for k, v in acc.txStorage:
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
  for address, acc in ledger.dirty:
    yield (address, acc)

# ------------------------------------------------------------------------------
# Public AccountRef read-only methods
# ------------------------------------------------------------------------------

func originalStatement*(acc: AccountRef): lent CoreDbAccount =
  acc.originalStatement

func statement*(acc: AccountRef): lent CoreDbAccount =
  acc.statement

func balanceChanged*(acc: AccountRef): bool =
  acc.statement.balance != acc.originalStatement.balance

func nonceChanged*(acc: AccountRef): bool =
  acc.statement.nonce != acc.originalStatement.nonce

func codeChanged*(acc: AccountRef): bool =
  CodeChanged in acc.flags

func storageChanged*(acc: AccountRef): bool =
  StorageChanged in acc.flags

func codeChangedToSomething*(acc: AccountRef): bool =
  acc.originalStatement.codeHash == EMPTY_CODE_HASH and
    acc.statement.codeHash != EMPTY_CODE_HASH

func slots*(acc: AccountRef): seq[UInt256] =
  for key in acc.overlayStorage.keys:
    result.add key

func storage*(acc: AccountRef, slot: UInt256): UInt256 =
  acc.overlayStorage.getOrDefault(slot)

func originalStorage*(acc: AccountRef, slot: UInt256): UInt256 =
  acc.heldStorage.withValue(slot, v):
    return v[]

  acc.txStorage.getOrDefault(slot)

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
proc isAccountEmpty*(ledger: ReadOnlyLedger, address: Address): bool = isAccountEmpty(distinctBase ledger, address)
proc getCommittedStorage*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): UInt256 = getCommittedStorage(distinctBase ledger, address, slot)
proc inAccessList*(ledger: ReadOnlyLedger, address: Address): bool = inAccessList(distinctBase ledger, address)
proc inAccessList*(ledger: ReadOnlyLedger, address: Address, slot: UInt256): bool = inAccessList(distinctBase ledger, address, slot)
proc getLiveAccount*(ledger: ReadOnlyLedger, address: Address): AccountRef = getLiveAccount(distinctBase ledger, address)
proc getDirtyAccount*(ledger: ReadOnlyLedger, address: Address): AccountRef = getDirtyAccount(distinctBase ledger, address)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
