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
  ../utils/utils,
  ../evm/code_bytes,
  ../constants,
  ../block_access_list/bal_overlay,
  ./[access_list as ac_access_list, core_db, storage_types],
  ./aristo/[aristo_blobify, aristo_desc, aristo_get]

export
  code_bytes, core_db.computeAccPath, core_Db.computeSlotKey

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
    ClearAccountPreserveBalance

  AccountFlags = set[AccountFlag]

  # Store original value from the database. Embedded in `AccountRef` rather
  # than a ref of its own: save points no longer clone accounts, so no two
  # accounts ever share one of these and the second allocation per account load
  # bought nothing.
  OriginalValue = object
    statement: CoreDbAccount
    storage:   Table[UInt256, UInt256]
    code: CodeBytesRef

  AccountRef = ref object
    statement: CoreDbAccount
    accPath: Hash32
    flags: AccountFlags
    code: CodeBytesRef
    original: OriginalValue
    overlayStorage: Table[UInt256, UInt256]

  JournalKind = enum
    jkCreate
    jkFlags
    jkBalance
    jkNonce
    jkCode
    jkStorage
    jkClearStorage
    jkSelfDestruct
    jkAccessListAccount
    jkAccessListSlot

  JournalEntry = object
    ## Undo record for a single mutation - see `LedgerRef.journal`
    acc: AccountRef
    case kind: JournalKind
    of jkCreate, jkSelfDestruct, jkAccessListAccount:
      address: Address
    of jkAccessListSlot:
      alAddress: Address
      alSlot: UInt256
    of jkFlags:
      prevFlags: AccountFlags
    of jkBalance:
      prevBalance: UInt256
    of jkNonce:
      prevNonce: AccountNonce
    of jkCode:
      prevCodeHash: Hash32
      prevCode: CodeBytesRef
    of jkStorage:
      slot: UInt256
      prevValue: UInt256
      hadValue: bool
    of jkClearStorage:
      prevOverlayStorage: Table[UInt256, UInt256]
      prevOriginalStorage: Table[UInt256, UInt256]

  LedgerRef* = ref object
    txFrame*: CoreDbTxRef

    accounts: Table[Address, AccountRef]
      ## All accounts touched since the last `persist`, in their current state.
      ## Save points do not own a copy of the accounts they modify: mutations
      ## are applied here in place and recorded in `journal` instead, so that a
      ## lookup never has to walk the save point stack.
    dirty: Table[Address, AccountRef]
      ## Subset of `accounts` that `persist` has to visit
    absent: HashSet[Address]
      ## Addresses a lookup has already proven to have no account, so a repeat
      ## lookup can skip recomputing the keccak account path and re-walking the
      ## trie only to reach the same conclusion. Needs no undo record: a roll
      ## back cannot conjure an account into existence, and an address that did
      ## exist would have been found in `accounts` and never recorded here.
      ## Creating an account for one of these addresses removes it, and
      ## `persist` clears the set outright.
    selfDestructs: HashSet[Address]
    accessList: ac_access_list.AccessList
    journal: seq[JournalEntry]
      ## Append-only log of the undo information for every mutation applied
      ## since the last `persist`. Rolling a save point back means replaying
      ## the tail of this log backwards; committing one means keeping it around
      ## so that an enclosing save point can still undo it.
    savePoints: seq[LedgerSpRef]
      ## Stack of open save points, the outermost one being created by `init`

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
    journalIdx: int
      ## Length of the ledger journal when this save point was opened
    depth: int
      ## Position in the save point stack, or 0 once committed/rolled back

const
  resetFlags = {
    Dirty,
    IsNew,
    Touched,
    CodeChanged,
    StorageChanged,
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

const
  MissingNodeErrors = {HikeBranchUnresolvedEdge, HikeDanglingEdge}
    ## A trie node this read's path needs is missing locally, so unlike a
    ## proof of absence we can't tell if the account/slot exists. Covers an
    ## incomplete witness (stateless) or a not-yet-fetched trie (verified proxy).

proc setFlags(ledger: LedgerRef, acc: AccountRef, flags: AccountFlags) =
  if acc.flags != flags:
    ledger.journal.add JournalEntry(kind: jkFlags, acc: acc, prevFlags: acc.flags)
    acc.flags = flags

proc undoJournal(ledger: LedgerRef, journalIdx: int) =
  var i = ledger.journal.high
  while i >= journalIdx:
    let e = addr ledger.journal[i]
    case e.kind
    of jkCreate:
      ledger.accounts.del(e.address)
      ledger.dirty.del(e.address)
    of jkFlags:
      e.acc.flags = e.prevFlags
    of jkBalance:
      e.acc.statement.balance = e.prevBalance
    of jkNonce:
      e.acc.statement.nonce = e.prevNonce
    of jkCode:
      e.acc.statement.codeHash = e.prevCodeHash
      e.acc.code = e.prevCode
    of jkStorage:
      if e.hadValue:
        e.acc.overlayStorage[e.slot] = e.prevValue
      else:
        e.acc.overlayStorage.del(e.slot)
    of jkClearStorage:
      e.acc.overlayStorage = move(e[].prevOverlayStorage)
      e.acc.original.storage = move(e[].prevOriginalStorage)
    of jkSelfDestruct:
      ledger.selfDestructs.excl(e.address)
    of jkAccessListAccount:
      ledger.accessList.remove(e.address)
    of jkAccessListSlot:
      ledger.accessList.remove(e.alAddress, e.alSlot)
    dec i

  ledger.journal.setLen(journalIdx)

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

  ledger.accounts.withValue(address, acc):
    return acc[]

  if ledger.cache.pop(address, result):
    # Check second-level cache
    ledger.accounts[address] = result
    ledger.journal.add JournalEntry(kind: jkCreate, address: address)
    return

  # An earlier lookup already proved there is no such account. Read-only callers
  # can stop here; one that intends to create the account has to fall through,
  # since it still needs `accPath` and must run the creation path rather than be
  # told the account is missing.
  if not shouldCreate and address in ledger.absent:
    return nil

  # not found in cache, look into state trie
  let
    accPath = address.computeAccPath
    rc = ledger.txFrame.fetchAccount accPath
    missingNode =
      rc.isErr and rc.error.isAristo and rc.error.aErr in MissingNodeErrors

  if missingNode:
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
      flags:     {Alive},
    )

  if ledger.balOverlay.isSome() and ledger.balOverlay[].hasAccount(address):
    # Acc found in the BAL overlay
    if result.isNil():
      result = AccountRef(
        statement: EMPTY_STATEMENT,
        accPath:   accPath,
        flags:    {Alive}
      )
    ledger.applyOverlay(address, result)
    # If the account from the overlay is empty, it was self destructed
    # and so we treat it as such.
    if result.isEmpty():
      result = nil

  var created = false
  if not result.isNil:
    # Field-wise rather than building a temporary, which would copy the (empty)
    # storage table for nothing.
    result.original.statement = result.statement
    result.original.code = result.code
  elif shouldCreate:
    created = true
    result = AccountRef(
      statement: EMPTY_STATEMENT,
      accPath:    accPath,
      flags:      {Alive, IsNew},
      original: OriginalValue(
        statement: EMPTY_STATEMENT,
      )
    )
  else:
    # No account here. Remember that, unless the trie could not answer: a
    # missing witness node is not a proof of absence, and caching it would turn
    # a recoverable gap into a wrong answer for the rest of the block.
    if not missingNode:
      ledger.absent.incl address
    return # ignore, don't cache

  # cache the account
  ledger.accounts[address] = result
  if created:
    # Only a newly created account starts out with something to write. One
    # loaded from the trie is clean - flags are just {Alive}, so persistMode()
    # classifies it DoNothing and persist() would walk it to no effect - and
    # makeDirty() enters it here as soon as it is actually modified.
    ledger.dirty[address] = result
  ledger.journal.add JournalEntry(kind: jkCreate, address: address)
  # This address resolves now, so any recorded absence for it is stale.
  ledger.absent.excl address

template exists(acc: AccountRef): bool =
  Alive in acc.flags

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

proc kill(ledger: LedgerRef, acc: AccountRef) =
  acc.flags.excl Alive
  acc.overlayStorage.clear()
  acc.original.storage.clear()
  acc.statement = EMPTY_STATEMENT
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

  # Make sure that there is an account entry on the database. This is needed by
  # `Aristo` for updating the account's storage area reference. As a side effect,
  # this action also updates the latest statement data.
  ledger.txFrame.mergeAccount(acc.accPath, acc.statement).isOkOr:
    return err(info & $$error)

  # Save `overlayStorage[]` on database. An alias, not a copy: `original` is
  # embedded in the account now, so binding it by value would clone its table.
  template original: untyped = acc.original
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

proc makeDirty(ledger: LedgerRef, address: Address, acc: AccountRef) =
  ledger.isDirty = true
  if Dirty notin acc.flags:
    ledger.setFlags(acc, acc.flags + {Dirty})
    ledger.dirty[address] = acc

template getCodeSizeImpl(ledger: LedgerRef, acc: AccountRef): int =
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
        # A non-empty code hash whose length is missing from the database: record
        # a fatalError but still return 0 so the async EVM continues.
        warn logTxt "getCodeSize()", codeHash=acc.statement.codeHash, error=($$rc.error)
        ledger.fatalError = Opt.some("getCodeSize(): failed to fetch code length from database")
        0

  acc.code.len()

# ------------------------------------------------------------------------------
# Public methods
# ------------------------------------------------------------------------------

# The LedgerRef is modeled after TrieDatabase for it's transaction style
proc init*(x: typedesc[LedgerRef], db: CoreDbTxRef): LedgerRef =
  init(x, db, false)

proc getStateRoot*(ledger: LedgerRef): Hash32 =
  # make sure all savePoint already committed
  doAssert(ledger.savePoints.len == 1)
  # make sure all cache already committed
  doAssert(ledger.isDirty == false)
  ledger.txFrame.getStateRoot().expect("working database")

proc isTopLevelClean*(ledger: LedgerRef): bool =
  ## Getter, returns `true` if all pending data have been commited.
  not ledger.isDirty and ledger.savePoints.len == 1

proc beginSavePoint*(ledger: LedgerRef): LedgerSpRef =
  result = LedgerSpRef(
    journalIdx: ledger.journal.len,
    depth: ledger.savePoints.len + 1,
  )
  ledger.savePoints.add(result)

proc rollback*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ledger.savePoints.len > 1 and ledger.savePoints[^1] == savePoint

  ledger.savePoints.setLen(ledger.savePoints.len - 1)
  savePoint.depth = 0

  ledger.undoJournal(savePoint.journalIdx)

proc commit*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  # Transactions should be handled in a strictly nested fashion.
  # Any child transaction must be committed or rolled-back before
  # its parent transactions:
  doAssert ledger.savePoints.len > 1 and ledger.savePoints[^1] == savePoint

  # Nothing to merge - the changes were applied directly to the ledger. The
  # journal is kept so that an enclosing save point can still undo them.
  ledger.savePoints.setLen(ledger.savePoints.len - 1)
  savePoint.depth = 0

proc dispose*(ledger: LedgerRef, savePoint: LedgerSpRef) =
  if savePoint.depth > 1:
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
  # Absence was proven against the previous frame and its overlay, neither of
  # which is in force any more.
  ledger.absent.clear()

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

  if acc.code.isNil:
    acc.code =
      if acc.statement.codeHash != EMPTY_CODE_HASH:
        ledger.code.get(acc.statement.codeHash).valueOr:
          var rc = ledger.txFrame.get(contractHashKey(acc.statement.codeHash).toOpenArray)
          if rc.isErr:
            # A non-empty code hash with no code in the database: record a fatalError
            # but still return empty code so the async EVM continues.
            warn logTxt "getCode()", codeHash=acc.statement.codeHash, error=($$rc.error)
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
  if ledger.collectWitness:
    let lookupKey = (address, Opt.none(UInt256))
    ledger.witnessKeys[lookupKey] = true

  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return CodeBytesRef()

  if acc.original.code.isNil:
    acc.original.code =
      if acc.original.statement.codeHash != EMPTY_CODE_HASH:
        ledger.code.get(acc.original.statement.codeHash).valueOr:
          var rc = ledger.txFrame.get(contractHashKey(acc.original.statement.codeHash).toOpenArray)
          if rc.isErr:
            warn logTxt "getCode()", codeHash=acc.original.statement.codeHash, error=($$rc.error)
            CodeBytesRef()
          else:
            let newCode = CodeBytesRef.init(move(rc.value), persisted = true)
            ledger.code.put(acc.original.statement.codeHash, newCode)
            newCode
      else:
        CodeBytesRef()

  acc.original.code

proc getCodeSize*(ledger: LedgerRef, address: Address): int =
  if ledger.collectWitness:
    let lookupKey = (address, Opt.none(UInt256))
    # We overwrite any existing record here so that codeTouched is always set to
    # true even if an account was previously accessed without touching the code
    ledger.witnessKeys[lookupKey] = true

  let acc = ledger.getAccount(address, false)
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

proc isDeadAccount*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return true
  if not acc.exists():
    return true
  acc.isEmpty()

proc originalAccountEmpty*(ledger: LedgerRef, address: Address): bool =
  let acc = ledger.getAccount(address, false)
  if acc.isNil:
    return true
  acc.original.statement == EMPTY_STATEMENT

proc setBalance*(ledger: LedgerRef, address: Address, balance: UInt256) =
  let acc = ledger.getAccount(address)
  ledger.setFlags(acc, acc.flags + {Alive})
  if acc.statement.balance != balance:
    ledger.makeDirty(address, acc)
    ledger.journal.add JournalEntry(
      kind: jkBalance, acc: acc, prevBalance: acc.statement.balance)
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
        ledger.makeDirty(address, acc)
        ledger.setFlags(acc, acc.flags + {Touched})
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
  ledger.setFlags(acc, acc.flags + {Alive})
  if acc.statement.nonce != nonce:
    ledger.makeDirty(address, acc)
    ledger.journal.add JournalEntry(
      kind: jkNonce, acc: acc, prevNonce: acc.statement.nonce)
    acc.statement.nonce = nonce

proc incNonce*(ledger: LedgerRef, address: Address) =
  ledger.setNonce(address, ledger.getNonce(address) + 1)

proc setCode*(ledger: LedgerRef, address: Address, code: seq[byte]) =
  let acc = ledger.getAccount(address)
  ledger.setFlags(acc, acc.flags + {Alive})
  let codeHash = keccak256(code)
  if acc.statement.codeHash != codeHash:
    ledger.makeDirty(address, acc)
    ledger.journal.add JournalEntry(kind: jkCode, acc: acc,
      prevCodeHash: acc.statement.codeHash, prevCode: acc.code)
    acc.statement.codeHash = codeHash
    # Try to reuse cache entry if it exists, but don't save the code - it's not
    # a given that it will be executed within LRU range
    acc.code = ledger.code.get(codeHash).valueOr(CodeBytesRef.init(code))
    ledger.setFlags(acc, acc.flags + {CodeChanged})

proc setStorage*(ledger: LedgerRef, address: Address, slot, value: UInt256) =
  let acc = ledger.getAccount(address)
  ledger.setFlags(acc, acc.flags + {Alive})

  if ledger.collectWitness:
    let lookupKey = (address, Opt.some(slot))
    if not ledger.witnessKeys.contains(lookupKey):
      ledger.witnessKeys[lookupKey] = false

  let oldValue = acc.storageValue(address, slot, ledger)
  if oldValue != value:
    ledger.makeDirty(address, acc)

    var entry = JournalEntry(kind: jkStorage, acc: acc, slot: slot)
    acc.overlayStorage.withValue(slot, v):
      entry.hadValue = true
      entry.prevValue = v[]
      v[] = value
    do:
      acc.overlayStorage[slot] = value
    ledger.journal.add(move entry)

    ledger.setFlags(acc, acc.flags + {StorageChanged})

proc clearStorage*(ledger: LedgerRef, address: Address) =
  # If there is an existing account with the given address, it is overwritten.
  let acc = ledger.getAccount(address)
  ledger.setFlags(acc, acc.flags + {Alive, NewlyCreated})

  if ledger.txFrame.hasStorage(acc.accPath).valueOr(false):
    # need to clear the storage from the database first
    ledger.makeDirty(address, acc)
    # also clear originalStorage cache, otherwise
    # both getStorage and getCommittedStorage will
    # return wrong value
    var entry = JournalEntry(kind: jkClearStorage, acc: acc)
    entry.prevOverlayStorage = move(acc.overlayStorage)
    entry.prevOriginalStorage = move(acc.original.storage)
    acc.overlayStorage.reset()
    acc.original.storage.reset()
    ledger.journal.add(move entry)

proc deleteAccount(ledger: LedgerRef, address: Address) =
  # make sure all savePoints already committed
  doAssert(ledger.savePoints.len == 1)
  let acc = ledger.getAccount(address)
  ledger.dirty[address] = acc
  if ClearAccountPreserveBalance in acc.flags:
    if ledger.txFrame.hasStorage(acc.accPath).valueOr(false):
      acc.original.storage.clear()
      acc.overlayStorage.clear()
    else:
      acc.flags.excl StorageChanged
      acc.overlayStorage.clear()

    acc.statement.nonce = 0

    if acc.statement.codeHash != EMPTY_ACCOUNT.codeHash:
      acc.flags.incl CodeChanged
      acc.statement.codeHash = EMPTY_ACCOUNT.codeHash
      acc.code = CodeBytesRef.init(@[])

    if acc.isEmpty:
      ledger.kill acc
  else:
    ledger.kill acc

proc markSelfDestruct(ledger: LedgerRef, address: Address) =
  if not ledger.selfDestructs.containsOrIncl(address):
    ledger.journal.add JournalEntry(kind: jkSelfDestruct, address: address)

proc selfDestruct*(ledger: LedgerRef, address: Address) =
  ledger.setBalance(address, 0.u256)
  ledger.markSelfDestruct(address)

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
    ledger.setFlags(acc, acc.flags + {ClearAccountPreserveBalance})
    ledger.markSelfDestruct(address)
    true
  else:
    false

proc selfDestructLen*(ledger: LedgerRef): int =
  ledger.selfDestructs.len

proc ripemdSpecial*(ledger: LedgerRef) =
  ledger.ripemdSpecial = true

proc clearEmptyAccounts(ledger: LedgerRef) =
  # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  for acc in ledger.dirty.values():
    if Touched in acc.flags and
        acc.isEmpty and acc.exists:
      ledger.kill acc

  # https://github.com/ethereum/EIPs/issues/716
  if ledger.ripemdSpecial:
    let acc = ledger.getAccount(RIPEMD_ADDR, false)
    if not acc.isNil and acc.isEmpty and acc.exists:
      ledger.dirty[RIPEMD_ADDR] = acc
      ledger.kill acc

    ledger.ripemdSpecial = false

template getWitnessKeys*(ledger: LedgerRef): WitnessTable =
  ledger.witnessKeys

proc getCollapsedSiblings*(
    ledger: LedgerRef
): seq[tuple[sibAccPath: Hash32, sibStoPath: Opt[Hash32]]] =
  ## Collapsed siblings for witness generation. StoLeaf collapses (brVid
  ## valid) are only included if brVid is still a StoLeaf in the final trie.
  ## A branch there means a later insertion expanded it again, no auxiliary
  ## needed.
  let db = ledger.txFrame.aTx
  var res: seq[tuple[sibAccPath: Hash32, sibStoPath: Opt[Hash32]]]
  for (accPath, sibStoPath, stoRoot, brVid) in db.collapsedSiblings:
    if brVid.isValid:
      let vtx = db.getVtx((stoRoot, brVid))
      if vtx.isValid and vtx.vType == StoLeaf:
        res.add((accPath, sibStoPath))
    else:
      res.add((accPath, sibStoPath))
  res

template clearWitnessKeys*(ledger: LedgerRef) =
  ledger.witnessKeys.clear()

template clearCollapsedSiblings*(ledger: LedgerRef) =
  ledger.txFrame.aTx.collapsedSiblings.setLen(0)

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
  doAssert(ledger.savePoints.len == 1)

  for address in ledger.selfDestructs:
    ledger.deleteAccount(address)

  if clearEmptyAccount:
    ledger.clearEmptyAccounts()

  for (address, acc) in ledger.dirty.pairs(): # This is a hotspot in block processing
    case acc.persistMode()
    of Update:
      if CodeChanged in acc.flags:
        acc.persistCode(ledger)
      if NewlyCreated in acc.flags or ClearAccountPreserveBalance in acc.flags:
        # TODO https://github.com/status-im/nimbus-eth1/issues/4024
        # When overwriting an account, other clients clear storage - it seems
        # however there's limited spec clarity on this point - in particular,
        # conformance tests pass both with and without this line at the time of
        # writing!
        ledger.txFrame.clearStorage(acc.accPath).expect("can clear storage of account")

      if StorageChanged in acc.flags:
        acc.persistStorage(ledger).isOkOr:
          ledger.setFatalErrorOrAssert(error)
      else:
        # This one is only necessary unless `persistStorage()` is run which needs
        # to `merge()` the latest statement as well.
        ledger.txFrame.mergeAccount(acc.accPath, acc.statement).isOkOr:
          ledger.setFatalErrorOrAssert(info & $$error)

      acc.original.statement = acc.statement
      acc.original.code = acc.code
    of Remove:
      ledger.txFrame.deleteAccount(acc.accPath).isOkOr:
        if error.error != AccNotFound:
          ledger.setFatalErrorOrAssert(info & $$error)
      ledger.accounts.del address
      acc.original.statement = EMPTY_STATEMENT
      acc.original.code = nil
    of DoNothing:
      # dead man tell no tales
      # remove touched dead account from cache
      if Alive notin acc.flags:
        ledger.accounts.del address

    acc.flags = acc.flags - resetFlags

  if clearCache:
    # This overwrites the cache from the previous persist, providing a crude LRU
    # scheme with little overhead
    # TODO https://github.com/nim-lang/Nim/issues/23759
    swap(ledger.cache, ledger.accounts)
    ledger.accounts.reset()

  ledger.dirty.clear()
  ledger.selfDestructs.clear()
  ledger.accessList.clear() # EIP2929
  # Accounts were just written to the trie and deleted ones dropped from the
  # cache, so absence proven against the pre-persist state no longer holds.
  ledger.absent.clear()
  ledger.journal.setLen(0) # Nothing left to roll back to

  ledger.isDirty = false

  if clearWitness:
    ledger.clearWitnessKeys()
    ledger.clearCollapsedSiblings()
    ledger.clearBlockHashesCache()

iterator addresses*(ledger: LedgerRef): Address =
  # make sure all savePoint already committed
  doAssert(ledger.savePoints.len == 1)
  for address, _ in ledger.accounts:
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
  if ledger.accessList.addIfAbsent(address):
    ledger.journal.add JournalEntry(kind: jkAccessListAccount, address: address)

proc accessList*(ledger: LedgerRef, address: Address, slot: UInt256) =
  let (addressAdded, slotAdded) = ledger.accessList.addIfAbsent(address, slot)
  if addressAdded:
    ledger.journal.add JournalEntry(kind: jkAccessListAccount, address: address)
  if slotAdded:
    ledger.journal.add JournalEntry(
      kind: jkAccessListSlot, alAddress: address, alSlot: slot)

func inAccessList*(ledger: LedgerRef, address: Address): bool =
  ledger.accessList.contains(address)

func inAccessList*(ledger: LedgerRef, address: Address, slot: UInt256): bool =
  ledger.accessList.contains(address, slot)

func getAccessList*(ledger: LedgerRef): transactions.AccessList =
  # make sure all savePoint already committed
  doAssert(ledger.savePoints.len == 1)
  ledger.accessList.getAccessList()

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

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
