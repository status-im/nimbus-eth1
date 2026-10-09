# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

# Tracks the state accesses and changes made while executing a block so that a
# BlockAccessList (EIP-7928) can be built from them.
#
# All of a transaction's accesses live in two flat entry lists, one per account
# and one per storage slot, each with an open addressing index over it. Call
# frames do not get structures of their own: a frame records how long the
# journal was when it began, every change appends an undo record to the
# journal, and a revert replays the journal back to the frame's mark, turning
# the frame's storage writes into reads as the EIP requires. A value changed
# several times within one frame gets a single undo record, the one taken
# before the first change, so the journal grows with the distinct values a
# frame touches rather than with its instruction count. Reads and touched
# accounts survive a revert and are therefore not journaled; the one rollback
# that discards them too, a transaction the block cannot take, happens at the
# transaction frame and simply clears everything. Committing a frame therefore
# costs nothing, reverting costs the frame's own changes, and the lists are
# reused from one transaction to the next without allocating.
#
# An account created and self-destructed in the same transaction is flagged on
# its entry and resolved once at the end of the transaction, when its storage
# writes become reads and its nonce and code changes are dropped.

import
  eth/common/addresses,
  eth/keccak/rapidhash,
  stew/ptrops,
  stint,
  ../db/ledger,
  ./bal_builder

export addresses, bal_builder, ledger, stint

type
  StorageKey = tuple[address: Address, slot: UInt256]

  # Plain data on purpose: an entry with a seq field would make every append
  # and truncation of the entry list a generic assignment under refc rather
  # than a copy. Code bytes therefore live in the tracker's `codes` list and
  # are referred to by position, with -1 for none.
  AccountEntry = object
    address: Address
    bucket: int32 ## position in the account index, for clearing
    touched: bool
    balanceWritten: bool
    nonceWritten: bool
    codeWritten: bool
    preBalanceKnown: bool
    preNonceKnown: bool
    preBalance: UInt256 ## balance before the transaction, see `preBalanceKnown`
    postBalance: UInt256 ## latest balance written
    preNonce: AccountNonce
    postNonce: AccountNonce
    preCode: int32 ## code before the transaction, -1 while unknown
    postCode: int32 ## latest code written
    selfDestructed: bool ## created and self-destructed in this transaction
    lastBalanceJournal: int32 ## journal position of the latest balance record
    lastNonceJournal: int32 ## journal position of the latest nonce record
    lastCodeJournal: int32 ## journal position of the latest code record

  StorageEntry = object
    key: StorageKey
    bucket: int32 ## position in the storage index, for clearing
    account: int32 ## position of the owning account entry
    read: bool
    written: bool
    preKnown: bool
    pre: UInt256 ## value before the transaction, see `preKnown`
    post: UInt256 ## latest value written
    lastJournal: int32 ## journal position of the latest write record

  JournalKind = enum
    jStorageWrite ## a storage entry's post value and written flag changed
    jBalance
    jNonce
    jCode
    jSelfDestruct ## the account's self-destructed flag was set

  JournalEntry = object
    idx: int32 ## entry position in the account or storage list
    prevCode: int32 ## previous post code position for code changes
    prevLast: int32 ## the entry's previous record position, see `lastJournal`
    kind: JournalKind
    prevWritten: bool
    prev: UInt256 ## previous post value for storage and balance changes
    prevNonce: AccountNonce

  FrameMark = object
    journalLen: int32

  # Entries in insertion order with an open addressing index over them, so
  # that an entry can be referred to by its position. Keys live in the entries;
  # a bucket holds a position + 1, 0 being empty. Entries are only ever removed
  # from the end, which keeps every older entry's probe sequence intact under
  # linear probing.
  PosTable[K, E] = object
    entries: seq[E]
    buckets: seq[int32]

  # Tracks state changes during transaction execution for block access list
  # construction. This tracker coordinates with the BlockAccessListBuilder to
  # record all state changes made during block execution. It ensures that only
  # actual changes (not no-op writes) are recorded in the access list.
  BlockAccessListTrackerRef* = ref object
    ledger*: ReadOnlyLedger ## Used to fetch the pre-transaction values from the state.
    builder*: ptr BlockAccessListBuilder
    builderOwner*: bool
    currentBlockAccessIndex*: int
      ## The current block access index (0 for pre-execution,
      ## 1..n for transactions, n+1 for post-execution).
    accounts: PosTable[Address, AccountEntry]
    storage: PosTable[StorageKey, StorageEntry]
    journal: seq[JournalEntry]
    codes: seq[seq[byte]] ## code bytes referred to by the account entries
    lastAccount: int32 ## entry of the most recently resolved address, or -1
    lastStorage: int32 ## entry of the most recently resolved slot, or -1
    frames: seq[FrameMark]
    blockAccessList: Opt[BlockAccessListRef]
      ## Created by the builder and cached for reuse.

const
  initialBuckets = 64

func indexHash(address: Address): uint64 =
  cast[uint64](hash(address))

func indexHash(key: StorageKey): uint64 =
  # The slot bytes hashed with the address hash as the seed, so that the pair
  # costs one hash call and inherits whatever seeding the address hash has.
  rapidhashNano(cast[ptr array[32, byte]](unsafeAddr key.slot)[], indexHash(key.address))

template indexKey(e: AccountEntry): Address =
  e.address

template indexKey(e: StorageEntry): StorageKey =
  e.key

func init(T: type AccountEntry, address: Address, bucket: int32): T =
  AccountEntry(
    address: address,
    bucket: bucket,
    preCode: -1,
    postCode: -1,
    lastBalanceJournal: -1,
    lastNonceJournal: -1,
    lastCodeJournal: -1,
  )

func init(T: type StorageEntry, key: StorageKey, bucket: int32): T =
  StorageEntry(key: key, bucket: bucket, lastJournal: -1)

# ------------------------------------------------------------------------------
# Position table
# ------------------------------------------------------------------------------

template len(t: PosTable): int =
  t.entries.len

template `[]`(t: PosTable, pos: SomeInteger): untyped =
  t.entries[pos]

iterator items[K, E](t: PosTable[K, E]): lent E =
  for i in 0 ..< t.entries.len:
    yield t.entries[i]

proc rehash[K, E](t: var PosTable[K, E], size: int) =
  t.buckets = newSeq[int32](size)
  let
    mask = uint64(size - 1)
    bk = makeUncheckedArray(baseAddr(t.buckets))
  for i in 0 ..< t.entries.len:
    var b = int(indexHash(t.entries[i].indexKey) and mask)
    while bk[b] != 0:
      b = int((uint64(b) + 1) and mask)
    bk[b] = int32(i + 1)
    t.entries[i].bucket = int32(b)

proc getOrAdd[K, E](t: var PosTable[K, E], key: K): tuple[pos: int32, added: bool] {.inline.} =
  ## Position of the key's entry, adding a fresh one if there is none. The
  ## load stays below one half.
  mixin init
  if t.buckets.len == 0:
    t.buckets = newSeq[int32](initialBuckets)
  elif (t.entries.len + 1) * 2 > t.buckets.len:
    t.rehash(t.buckets.len * 2)

  let
    mask = uint64(t.buckets.len - 1)
    bk = makeUncheckedArray(baseAddr(t.buckets))
  var b = int(indexHash(key) and mask)
  while true:
    let e = bk[b]
    if e == 0:
      let pos = int32(t.entries.len)
      t.entries.add(E.init(key, int32(b)))
      bk[b] = pos + 1
      return (pos, true)
    if t.entries[e - 1].indexKey == key:
      return (e - 1, false)
    b = int((uint64(b) + 1) and mask)

proc truncate[K, E](t: var PosTable[K, E], len: int) =
  ## Drop the entries after the first `len`, clearing their buckets.
  for i in len ..< t.entries.len:
    t.buckets[t.entries[i].bucket] = 0
  t.entries.setLen(len)

# ------------------------------------------------------------------------------
# Account and storage entry lookup
# ------------------------------------------------------------------------------

proc accountEntry(tracker: BlockAccessListTrackerRef, address: Address): int32 =
  ## Position of the account's entry, creating an untouched one if new.
  # Accesses cluster on one account, the current target of the call frame.
  if tracker.lastAccount >= 0 and tracker.accounts[tracker.lastAccount].address == address:
    return tracker.lastAccount
  result = tracker.accounts.getOrAdd(address).pos
  tracker.lastAccount = result

proc storageEntry(tracker: BlockAccessListTrackerRef, key: StorageKey): int32 =
  ## Position of the slot's entry, creating one that is neither read nor
  ## written if new.
  # SSTORE resolves its slot twice, for the gas calculation and for the write.
  if tracker.lastStorage >= 0 and tracker.storage[tracker.lastStorage].key == key:
    return tracker.lastStorage
  let (pos, added) = tracker.storage.getOrAdd(key)
  if added:
    let account = tracker.accountEntry(key.address)
    tracker.storage[pos].account = account
  tracker.lastStorage = pos
  pos

proc clearTransaction(tracker: BlockAccessListTrackerRef) =
  tracker.accounts.truncate(0)
  tracker.lastAccount = -1
  tracker.storage.truncate(0)
  tracker.lastStorage = -1
  tracker.journal.setLen(0)
  tracker.codes.setLen(0)
  tracker.frames.setLen(0)

# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------

proc init*(
    T: type BlockAccessListTrackerRef,
    ledger: ReadOnlyLedger,
    builder: ptr BlockAccessListBuilder = nil,
): T =
  result = T(ledger: ledger, builder: builder, lastAccount: -1, lastStorage: -1)
  if builder.isNil():
    result.builder = BlockAccessListBuilder.newShared()
    result.builderOwner = true

proc dispose*(tracker: BlockAccessListTrackerRef) =
  if tracker.builderOwner:
    assert not tracker.builder.isNil()
    tracker.builder.dispose()
    tracker.builder = nil
    tracker.builderOwner = false

proc setBlockAccessIndex*(tracker: BlockAccessListTrackerRef, blockAccessIndex: int) =
  ## Must be called before processing each transaction/system contract
  ## to ensure changes are associated with the correct block access index.
  ## Note: Block access indices differ from transaction indices:
  ##   - 0: Pre-execution (system contracts like beacon roots, block hashes)
  ##   - 1..n: Transactions (tx at index i gets block_access_index i+1)
  ##   - n+1: Post-execution (withdrawals, requests)
  tracker.clearTransaction()
  tracker.currentBlockAccessIndex = blockAccessIndex

  tracker.builder[].ensureIndexCount(blockAccessIndex + 1)

template hasPendingCallFrame*(tracker: BlockAccessListTrackerRef): bool =
  tracker.frames.len() > 0

template hasParentCallFrame(tracker: BlockAccessListTrackerRef): bool =
  tracker.frames.len() > 1

proc beginCallFrame*(tracker: BlockAccessListTrackerRef) =
  ## Begin a new call frame for tracking reverts. Records where the frame
  ## begins in the journal so that a revert can undo exactly the frame's
  ## changes, as EIP-7928 requires.
  tracker.frames.add(FrameMark(journalLen: int32(tracker.journal.len)))

# ------------------------------------------------------------------------------
# Pre-transaction values
# ------------------------------------------------------------------------------

proc capturePreBalance(tracker: BlockAccessListTrackerRef, idx: int32) =
  if not tracker.accounts[idx].preBalanceKnown:
    tracker.accounts[idx].preBalance = tracker.ledger.getBalance(tracker.accounts[idx].address)
    tracker.accounts[idx].preBalanceKnown = true

proc capturePreNonce(tracker: BlockAccessListTrackerRef, idx: int32) =
  if not tracker.accounts[idx].preNonceKnown:
    tracker.accounts[idx].preNonce = tracker.ledger.getNonce(tracker.accounts[idx].address)
    tracker.accounts[idx].preNonceKnown = true

proc addCode(tracker: BlockAccessListTrackerRef, code: seq[byte]): int32 =
  result = int32(tracker.codes.len)
  tracker.codes.add(code)

template codeAt(tracker: BlockAccessListTrackerRef, pos: int32): seq[byte] =
  tracker.codes[pos]

proc capturePreCode(tracker: BlockAccessListTrackerRef, idx: int32) =
  if tracker.accounts[idx].preCode < 0:
    tracker.accounts[idx].preCode =
      tracker.addCode(tracker.ledger.getCode(tracker.accounts[idx].address).bytes)

proc capturePreStorage(tracker: BlockAccessListTrackerRef, idx: int32) =
  if not tracker.storage[idx].preKnown:
    let key = tracker.storage[idx].key
    tracker.storage[idx].pre = tracker.ledger.getStorage(key.address, key.slot)
    tracker.storage[idx].preKnown = true

template capturePre(known, pre: untyped, current: Opt, fallback: untyped) =
  ## Record the pre-transaction value on its first write: the value the caller
  ## has just read from the ledger when it passes one, otherwise the ledger's
  ## value right now.
  if not known:
    if current.isSome():
      pre = current[]
      known = true
    else:
      fallback

# ------------------------------------------------------------------------------
# Tracking
# ------------------------------------------------------------------------------

template touch(tracker: BlockAccessListTrackerRef, idx: int32) =
  tracker.accounts[idx].touched = true

proc trackAddressAccess*(tracker: BlockAccessListTrackerRef, address: Address) =
  assert tracker.hasPendingCallFrame()
  tracker.touch(tracker.accountEntry(address))

proc trackStorageRead*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
) =
  assert tracker.hasPendingCallFrame()
  let idx = tracker.storageEntry((address, slot))
  tracker.touch(tracker.storage[idx].account)
  tracker.storage[idx].read = true

proc recordOnce(
    tracker: BlockAccessListTrackerRef, last: var int32, entry: JournalEntry
) {.inline.} =
  ## Append the undo record `entry` unless `last`, the position of the entry's
  ## latest record of the same kind, lies within the current frame: the first
  ## record of a frame already holds the value to restore. An undo puts back
  ## the position a record replaced, so `last` always refers to a live record.
  if last >= tracker.frames[^1].journalLen:
    return
  tracker.journal.add(entry)
  tracker.journal[^1].prevLast = last
  last = int32(tracker.journal.len - 1)

proc trackStorageWrite*(
    tracker: BlockAccessListTrackerRef,
    address: Address,
    slot: UInt256,
    newValue: UInt256,
) =
  assert tracker.hasPendingCallFrame()
  let idx = tracker.storageEntry((address, slot))
  template e(): untyped =
    tracker.storage[idx]

  if e.written and e.post == newValue:
    return

  tracker.touch(e.account)
  tracker.capturePreStorage(idx)
  tracker.recordOnce(
    e.lastJournal,
    JournalEntry(kind: jStorageWrite, idx: idx, prevWritten: e.written, prev: e.post),
  )
  e.post = newValue
  e.written = true

proc trackBalanceChange(
    tracker: BlockAccessListTrackerRef,
    address: Address,
    newBalance: UInt256,
    current: Opt[UInt256],
) =
  assert tracker.hasPendingCallFrame()
  let idx = tracker.accountEntry(address)
  template e(): untyped =
    tracker.accounts[idx]

  if e.balanceWritten and e.postBalance == newBalance:
    return

  tracker.touch(idx)
  capturePre(e.preBalanceKnown, e.preBalance, current, tracker.capturePreBalance(idx))
  tracker.recordOnce(
    e.lastBalanceJournal,
    JournalEntry(
      kind: jBalance, idx: idx, prevWritten: e.balanceWritten, prev: e.postBalance
    ),
  )
  e.postBalance = newBalance
  e.balanceWritten = true

proc trackBalanceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, newBalance: UInt256
) =
  tracker.trackBalanceChange(address, newBalance, Opt.none(UInt256))

proc trackAddBalanceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, delta: UInt256
) =
  if delta.isZero:
    tracker.trackAddressAccess(address)
    return

  let current = tracker.ledger.getBalance(address)
  tracker.trackBalanceChange(address, current + delta, Opt.some(current))

proc trackSubBalanceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, delta: UInt256
) =
  if delta.isZero:
    # In this case we don't call trackAddressAccess because the account isn't read
    # due to early return as defined in EIP-4788
    return

  let current = tracker.ledger.getBalance(address)
  tracker.trackBalanceChange(address, current - delta, Opt.some(current))

proc trackNonceChange(
    tracker: BlockAccessListTrackerRef,
    address: Address,
    newNonce: AccountNonce,
    current: Opt[AccountNonce],
) =
  assert tracker.hasPendingCallFrame()
  let idx = tracker.accountEntry(address)
  template e(): untyped =
    tracker.accounts[idx]

  if e.nonceWritten and e.postNonce == newNonce:
    return

  tracker.touch(idx)
  capturePre(e.preNonceKnown, e.preNonce, current, tracker.capturePreNonce(idx))
  tracker.recordOnce(
    e.lastNonceJournal,
    JournalEntry(
      kind: jNonce, idx: idx, prevWritten: e.nonceWritten, prevNonce: e.postNonce
    ),
  )
  e.postNonce = newNonce
  e.nonceWritten = true

proc trackNonceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, newNonce: AccountNonce
) =
  tracker.trackNonceChange(address, newNonce, Opt.none(AccountNonce))

proc trackIncNonceChange*(tracker: BlockAccessListTrackerRef, address: Address) =
  let current = tracker.ledger.getNonce(address)
  tracker.trackNonceChange(address, current + 1, Opt.some(current))

proc trackCodeChange*(
    tracker: BlockAccessListTrackerRef, address: Address, newCode: seq[byte]
) =
  assert tracker.hasPendingCallFrame()
  let idx = tracker.accountEntry(address)
  template e(): untyped =
    tracker.accounts[idx]

  if e.codeWritten and tracker.codeAt(e.postCode) == newCode:
    return

  tracker.touch(idx)
  tracker.capturePreCode(idx)
  tracker.recordOnce(
    e.lastCodeJournal,
    JournalEntry(kind: jCode, idx: idx, prevWritten: e.codeWritten, prevCode: e.postCode),
  )
  e.postCode = tracker.addCode(newCode)
  e.codeWritten = true

proc trackInTransactionSelfDestruct*(
    tracker: BlockAccessListTrackerRef, address: Address
) =
  ## Flag an account created and self-destructed in this transaction. The flag
  ## is resolved at the end of the transaction and undone if the frame reverts.
  assert tracker.hasPendingCallFrame()
  let idx = tracker.accountEntry(address)
  tracker.touch(idx)
  if not tracker.accounts[idx].selfDestructed:
    tracker.accounts[idx].selfDestructed = true
    tracker.journal.add(JournalEntry(kind: jSelfDestruct, idx: idx))

# ------------------------------------------------------------------------------
# Call frames
# ------------------------------------------------------------------------------

proc normalizeChanges(tracker: BlockAccessListTrackerRef) =
  ## Resolve the accounts that self-destructed in the transaction they were
  ## created in: their storage writes count as reads and they end with a zero
  ## nonce and empty code. Then drop changes that leave a value as it was
  ## before the transaction; such a storage write still counts as a read.
  for idx in 0 ..< tracker.accounts.len:
    template e(): untyped =
      tracker.accounts[idx]

    if e.selfDestructed:
      tracker.touch(int32(idx))
      tracker.capturePreNonce(int32(idx))
      e.postNonce = 0
      e.nonceWritten = true
      tracker.capturePreCode(int32(idx))
      e.postCode = tracker.addCode(newSeq[byte]())
      e.codeWritten = true

    if e.balanceWritten and e.preBalance == e.postBalance:
      e.balanceWritten = false
    if e.nonceWritten and e.preNonce == e.postNonce:
      e.nonceWritten = false
    if e.codeWritten and tracker.codeAt(e.preCode) == tracker.codeAt(e.postCode):
      e.codeWritten = false

  for idx in 0 ..< tracker.storage.len:
    template e(): untyped =
      tracker.storage[idx]

    if e.written and (e.pre == e.post or tracker.accounts[e.account].selfDestructed):
      e.written = false
      e.read = true

proc recordTransaction(tracker: BlockAccessListTrackerRef) =
  ## Hand the transaction's accesses and changes to the builder.
  let index = tracker.currentBlockAccessIndex
  for e in tracker.accounts:
    if e.touched:
      tracker.builder[].addTouchedAccount(index, e.address)
    if e.balanceWritten:
      tracker.builder[].addBalanceChange(index, e.address, e.postBalance)
    if e.nonceWritten:
      tracker.builder[].addNonceChange(index, e.address, e.postNonce)
    if e.codeWritten:
      tracker.builder[].addCodeChange(index, e.address, tracker.codeAt(e.postCode))

  for e in tracker.storage:
    if e.written:
      tracker.builder[].addStorageWrite(index, e.key.address, e.key.slot, e.post)
    elif e.read:
      tracker.builder[].addStorageRead(index, e.key.address, e.key.slot)

proc commitCallFrame*(tracker: BlockAccessListTrackerRef) =
  ## Commit the current call frame: its changes stay in place. Committing the
  ## transaction's own frame records the transaction with the builder.
  doAssert tracker.hasPendingCallFrame()

  if tracker.hasParentCallFrame():
    tracker.frames.setLen(tracker.frames.len - 1)
  else:
    tracker.normalizeChanges()
    tracker.recordTransaction()
    tracker.clearTransaction()

proc undoJournal(tracker: BlockAccessListTrackerRef, mark: FrameMark) =
  ## Replay the journal back to `mark`. A reverted storage write becomes a
  ## read.
  var j = tracker.journal.len
  while j > int(mark.journalLen):
    dec j
    let entry = tracker.journal[j]
    case entry.kind
    of jStorageWrite:
      tracker.storage[entry.idx].post = entry.prev
      tracker.storage[entry.idx].written = entry.prevWritten
      tracker.storage[entry.idx].read = true
      tracker.storage[entry.idx].lastJournal = entry.prevLast
    of jBalance:
      tracker.accounts[entry.idx].postBalance = entry.prev
      tracker.accounts[entry.idx].balanceWritten = entry.prevWritten
      tracker.accounts[entry.idx].lastBalanceJournal = entry.prevLast
    of jNonce:
      tracker.accounts[entry.idx].postNonce = entry.prevNonce
      tracker.accounts[entry.idx].nonceWritten = entry.prevWritten
      tracker.accounts[entry.idx].lastNonceJournal = entry.prevLast
    of jCode:
      tracker.accounts[entry.idx].postCode = entry.prevCode
      tracker.accounts[entry.idx].codeWritten = entry.prevWritten
      tracker.accounts[entry.idx].lastCodeJournal = entry.prevLast
    of jSelfDestruct:
      tracker.accounts[entry.idx].selfDestructed = false
  tracker.journal.setLen(int(mark.journalLen))

proc rollbackCallFrame*(tracker: BlockAccessListTrackerRef) =
  ## Revert the current call frame. As specified in EIP-7928 the frame's
  ## storage writes become reads and its touched addresses remain. Reverting
  ## the transaction's own frame drops a transaction the block cannot take, so
  ## the transaction leaves no trace.
  doAssert tracker.hasPendingCallFrame()

  if tracker.hasParentCallFrame():
    tracker.undoJournal(tracker.frames[^1])
    tracker.frames.setLen(tracker.frames.len - 1)
  else:
    tracker.clearTransaction()

proc getBlockAccessList*(
    tracker: BlockAccessListTrackerRef, rebuild = false
): lent Opt[BlockAccessListRef] =
  if rebuild or tracker.blockAccessList.isNone():
    tracker.blockAccessList = Opt.some(tracker.builder[].buildBlockAccessList())

  tracker.blockAccessList
