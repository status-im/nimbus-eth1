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

{.push raises: [], gcsafe.}

import
  eth/common/addresses,
  eth/keccak/rapidhash,
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
    accounts: seq[AccountEntry]
    accountBuckets: seq[int32] ## account index: position + 1, 0 is empty
    storage: seq[StorageEntry]
    storageBuckets: seq[int32] ## storage index: position + 1, 0 is empty
    journal: seq[JournalEntry]
    codes: seq[seq[byte]] ## code bytes referred to by the account entries
    lastAccount: int32 ## entry of the most recently resolved address, or -1
    frames: seq[FrameMark]
    blockAccessList: Opt[BlockAccessListRef]
      ## Created by the builder and cached for reuse.

const
  initialBuckets = 64

func addrHash(address: Address): uint64 =
  uint64(hash(address))

func storageHash(key: StorageKey): uint64 =
  # The slot bytes hashed with the address hash as the seed, so that the pair
  # costs one hash call and inherits whatever seeding the address hash has.
  rapidhashNano(cast[ptr array[32, byte]](unsafeAddr key.slot)[], addrHash(key.address))

template dataPtr[T](s: seq[T]): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](unsafeAddr s[0])

# ------------------------------------------------------------------------------
# Account and storage entry lookup
# ------------------------------------------------------------------------------

proc rehashAccounts(tracker: BlockAccessListTrackerRef, size: int) =
  tracker.accountBuckets = newSeq[int32](size)
  let
    mask = uint64(size - 1)
    bk = tracker.accountBuckets.dataPtr()
  for i in 0 ..< tracker.accounts.len:
    var b = int(addrHash(tracker.accounts[i].address) and mask)
    while bk[b] != 0:
      b = int((uint64(b) + 1) and mask)
    bk[b] = int32(i + 1)
    tracker.accounts[i].bucket = int32(b)

proc accountEntry(tracker: BlockAccessListTrackerRef, address: Address): int32 =
  ## Position of the account's entry, creating an untouched one if new.
  # Accesses cluster on one account, the current target of the call frame.
  if tracker.lastAccount >= 0 and tracker.accounts[tracker.lastAccount].address == address:
    return tracker.lastAccount

  if tracker.accountBuckets.len == 0:
    tracker.accountBuckets = newSeq[int32](initialBuckets)
  elif (tracker.accounts.len + 1) * 2 > tracker.accountBuckets.len:
    tracker.rehashAccounts(tracker.accountBuckets.len * 2)

  let
    mask = uint64(tracker.accountBuckets.len - 1)
    bk = tracker.accountBuckets.dataPtr()
  var b = int(addrHash(address) and mask)
  while true:
    let e = bk[b]
    if e == 0:
      result = int32(tracker.accounts.len)
      tracker.accounts.add(
        AccountEntry(
          address: address,
          bucket: int32(b),
          preCode: -1,
          postCode: -1,
          lastBalanceJournal: -1,
        )
      )
      bk[b] = result + 1
      tracker.lastAccount = result
      return
    if tracker.accounts[e - 1].address == address:
      tracker.lastAccount = e - 1
      return e - 1
    b = int((uint64(b) + 1) and mask)

proc findAccount(tracker: BlockAccessListTrackerRef, address: Address): int32 =
  ## Position of the account's entry, or -1.
  if tracker.accountBuckets.len == 0:
    return -1
  let
    mask = uint64(tracker.accountBuckets.len - 1)
    bk = tracker.accountBuckets.dataPtr()
  var b = int(addrHash(address) and mask)
  while true:
    let e = bk[b]
    if e == 0:
      return -1
    if tracker.accounts[e - 1].address == address:
      return e - 1
    b = int((uint64(b) + 1) and mask)

proc rehashStorage(tracker: BlockAccessListTrackerRef, size: int) =
  tracker.storageBuckets = newSeq[int32](size)
  let
    mask = uint64(size - 1)
    bk = tracker.storageBuckets.dataPtr()
  for i in 0 ..< tracker.storage.len:
    var b = int(storageHash(tracker.storage[i].key) and mask)
    while bk[b] != 0:
      b = int((uint64(b) + 1) and mask)
    bk[b] = int32(i + 1)
    tracker.storage[i].bucket = int32(b)

proc storageEntry(tracker: BlockAccessListTrackerRef, key: StorageKey): int32 =
  ## Position of the slot's entry, creating one that is neither read nor
  ## written if new.
  if tracker.storageBuckets.len == 0:
    tracker.storageBuckets = newSeq[int32](initialBuckets)
  elif (tracker.storage.len + 1) * 2 > tracker.storageBuckets.len:
    tracker.rehashStorage(tracker.storageBuckets.len * 2)

  let
    mask = uint64(tracker.storageBuckets.len - 1)
    bk = tracker.storageBuckets.dataPtr()
  var b = int(storageHash(key) and mask)
  while true:
    let e = bk[b]
    if e == 0:
      result = int32(tracker.storage.len)
      let account = tracker.accountEntry(key.address)
      tracker.storage.add(
        StorageEntry(key: key, bucket: int32(b), account: account, lastJournal: -1)
      )
      bk[b] = result + 1
      return
    if tracker.storage[e - 1].key == key:
      return e - 1
    b = int((uint64(b) + 1) and mask)

proc findStorage(tracker: BlockAccessListTrackerRef, key: StorageKey): int32 =
  ## Position of the slot's entry, or -1.
  if tracker.storageBuckets.len == 0:
    return -1
  let
    mask = uint64(tracker.storageBuckets.len - 1)
    bk = tracker.storageBuckets.dataPtr()
  var b = int(storageHash(key) and mask)
  while true:
    let e = bk[b]
    if e == 0:
      return -1
    if tracker.storage[e - 1].key == key:
      return e - 1
    b = int((uint64(b) + 1) and mask)

proc truncateAccounts(tracker: BlockAccessListTrackerRef, len: int) =
  ## Drop the account entries created after the first `len`. Entries are only
  ## ever removed from the end, which keeps every older entry's probe sequence
  ## intact under linear probing.
  for i in len ..< tracker.accounts.len:
    tracker.accountBuckets[tracker.accounts[i].bucket] = 0
  tracker.accounts.setLen(len)
  if tracker.lastAccount >= len:
    tracker.lastAccount = -1

proc truncateStorage(tracker: BlockAccessListTrackerRef, len: int) =
  for i in len ..< tracker.storage.len:
    tracker.storageBuckets[tracker.storage[i].bucket] = 0
  tracker.storage.setLen(len)

proc clearTransaction(tracker: BlockAccessListTrackerRef) =
  tracker.truncateAccounts(0)
  tracker.truncateStorage(0)
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
  if builder.isNil():
    BlockAccessListTrackerRef(
      ledger: ledger,
      builder: BlockAccessListBuilder.newShared(),
      builderOwner: true,
      lastAccount: -1,
    )
  else:
    BlockAccessListTrackerRef(
      ledger: ledger, builder: builder, builderOwner: false, lastAccount: -1
    )

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

template frameDepth*(tracker: BlockAccessListTrackerRef): int =
  tracker.frames.len()

template hasPendingCallFrame*(tracker: BlockAccessListTrackerRef): bool =
  tracker.frames.len() > 0

template hasParentCallFrame*(tracker: BlockAccessListTrackerRef): bool =
  tracker.frames.len() > 1

proc beginCallFrame*(tracker: BlockAccessListTrackerRef) =
  ## Begin a new call frame for tracking reverts. Records where the frame
  ## begins in the journal and entry lists so that a revert can undo exactly
  ## the frame's changes, as EIP-7928 requires.
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

proc capturePreBalance*(tracker: BlockAccessListTrackerRef, address: Address) =
  ## Record the account's balance before the transaction, without marking the
  ## account as accessed.
  tracker.capturePreBalance(tracker.accountEntry(address))

proc capturePreNonce*(tracker: BlockAccessListTrackerRef, address: Address) =
  tracker.capturePreNonce(tracker.accountEntry(address))

proc capturePreCode*(tracker: BlockAccessListTrackerRef, address: Address) =
  tracker.capturePreCode(tracker.accountEntry(address))

proc capturePreStorage*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
) =
  tracker.capturePreStorage(tracker.storageEntry((address, slot)))

func preBalance*(tracker: BlockAccessListTrackerRef, address: Address): Opt[UInt256] =
  ## The captured pre-transaction balance, if any.
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].preBalanceKnown:
    Opt.some(tracker.accounts[idx].preBalance)
  else:
    Opt.none(UInt256)

func preNonce*(tracker: BlockAccessListTrackerRef, address: Address): Opt[AccountNonce] =
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].preNonceKnown:
    Opt.some(tracker.accounts[idx].preNonce)
  else:
    Opt.none(AccountNonce)

func preCode*(tracker: BlockAccessListTrackerRef, address: Address): Opt[seq[byte]] =
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].preCode >= 0:
    Opt.some(tracker.codeAt(tracker.accounts[idx].preCode))
  else:
    Opt.none(seq[byte])

func preStorage*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): Opt[UInt256] =
  let idx = tracker.findStorage((address, slot))
  if idx >= 0 and tracker.storage[idx].preKnown:
    Opt.some(tracker.storage[idx].pre)
  else:
    Opt.none(UInt256)

template getPreBalance*(tracker: BlockAccessListTrackerRef, address: Address): UInt256 =
  tracker.preBalance(address).valueOr(0.u256)

template getPreNonce*(
    tracker: BlockAccessListTrackerRef, address: Address
): AccountNonce =
  tracker.preNonce(address).valueOr(0.AccountNonce)

template getPreCode*(tracker: BlockAccessListTrackerRef, address: Address): seq[byte] =
  tracker.preCode(address).valueOr(default(seq[byte]))

template getPreStorage*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): UInt256 =
  tracker.preStorage(address, slot).valueOr(0.u256)

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

func journaled(
    tracker: BlockAccessListTrackerRef, pos: int32, kind: JournalKind, idx: int32
): bool =
  ## Whether `pos` is a live record of `kind` for `idx` within the current
  ## frame. An undo restores the position the undone record replaced, so the
  ## check also fails when the entry's latest record lies in an enclosing frame.
  pos >= tracker.frames[^1].journalLen and pos < int32(tracker.journal.len) and
    tracker.journal[pos].kind == kind and tracker.journal[pos].idx == idx

# The pre-transaction value of a slot, balance or nonce is captured on its
# first write as whatever the ledger holds at that moment. A caller that has
# just read that value itself, as the SSTORE handler does for its gas
# calculation, passes it in so that it is not read a second time.

proc trackStorageWriteAt(
    tracker: BlockAccessListTrackerRef, idx: int32, newValue: UInt256, current: Opt[UInt256]
) =
  template e(): untyped =
    tracker.storage[idx]

  if e.written and e.post == newValue:
    return # nothing to do because we have already tracked this value

  tracker.touch(e.account)
  if not e.preKnown:
    if current.isSome():
      e.pre = current[]
      e.preKnown = true
    else:
      tracker.capturePreStorage(idx)
  if not tracker.journaled(e.lastJournal, jStorageWrite, idx):
    tracker.journal.add(
      JournalEntry(
        kind: jStorageWrite,
        idx: idx,
        prevWritten: e.written,
        prev: e.post,
        prevLast: e.lastJournal,
      )
    )
    e.lastJournal = int32(tracker.journal.len - 1)
  e.post = newValue
  e.written = true

proc trackStorageWrite*(
    tracker: BlockAccessListTrackerRef,
    address: Address,
    slot: UInt256,
    newValue: UInt256,
) =
  assert tracker.hasPendingCallFrame()
  tracker.trackStorageWriteAt(
    tracker.storageEntry((address, slot)), newValue, Opt.none(UInt256)
  )

proc trackStorageWrite*(
    tracker: BlockAccessListTrackerRef,
    address: Address,
    slot: UInt256,
    newValue: UInt256,
    currentValue: UInt256,
) =
  ## `currentValue` is the slot's value as the ledger holds it right now.
  assert tracker.hasPendingCallFrame()
  tracker.trackStorageWriteAt(
    tracker.storageEntry((address, slot)), newValue, Opt.some(currentValue)
  )

proc trackBalanceChangeAt(
    tracker: BlockAccessListTrackerRef,
    idx: int32,
    newBalance: UInt256,
    current: Opt[UInt256],
) =
  template e(): untyped =
    tracker.accounts[idx]

  if e.balanceWritten and e.postBalance == newBalance:
    return # nothing to do because we have already tracked this value

  tracker.touch(idx)
  if not e.preBalanceKnown:
    if current.isSome():
      e.preBalance = current[]
      e.preBalanceKnown = true
    else:
      tracker.capturePreBalance(idx)
  if not tracker.journaled(e.lastBalanceJournal, jBalance, idx):
    tracker.journal.add(
      JournalEntry(
        kind: jBalance,
        idx: idx,
        prevWritten: e.balanceWritten,
        prev: e.postBalance,
        prevLast: e.lastBalanceJournal,
      )
    )
    e.lastBalanceJournal = int32(tracker.journal.len - 1)
  e.postBalance = newBalance
  e.balanceWritten = true

proc trackBalanceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, newBalance: UInt256
) =
  assert tracker.hasPendingCallFrame()
  tracker.trackBalanceChangeAt(
    tracker.accountEntry(address), newBalance, Opt.none(UInt256)
  )

proc trackAddBalanceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, delta: UInt256
) =
  if delta.isZero:
    tracker.trackAddressAccess(address)
    return

  assert tracker.hasPendingCallFrame()
  let current = tracker.ledger.getBalance(address)
  tracker.trackBalanceChangeAt(
    tracker.accountEntry(address), current + delta, Opt.some(current)
  )

proc trackSubBalanceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, delta: UInt256
) =
  if delta.isZero:
    # In this case we don't call trackAddressAccess because the account isn't read
    # due to early return as defined in EIP-4788
    return

  assert tracker.hasPendingCallFrame()
  let current = tracker.ledger.getBalance(address)
  tracker.trackBalanceChangeAt(
    tracker.accountEntry(address), current - delta, Opt.some(current)
  )

proc trackNonceChangeAt(
    tracker: BlockAccessListTrackerRef,
    idx: int32,
    newNonce: AccountNonce,
    current: Opt[AccountNonce],
) =
  template e(): untyped =
    tracker.accounts[idx]

  if e.nonceWritten and e.postNonce == newNonce:
    return # nothing to do because we have already tracked this value

  tracker.touch(idx)
  if not e.preNonceKnown:
    if current.isSome():
      e.preNonce = current[]
      e.preNonceKnown = true
    else:
      tracker.capturePreNonce(idx)
  tracker.journal.add(
    JournalEntry(
      kind: jNonce, idx: idx, prevWritten: e.nonceWritten, prevNonce: e.postNonce
    )
  )
  e.postNonce = newNonce
  e.nonceWritten = true

proc trackNonceChange*(
    tracker: BlockAccessListTrackerRef, address: Address, newNonce: AccountNonce
) =
  assert tracker.hasPendingCallFrame()
  tracker.trackNonceChangeAt(
    tracker.accountEntry(address), newNonce, Opt.none(AccountNonce)
  )

proc trackIncNonceChange*(tracker: BlockAccessListTrackerRef, address: Address) =
  assert tracker.hasPendingCallFrame()
  let current = tracker.ledger.getNonce(address)
  tracker.trackNonceChangeAt(
    tracker.accountEntry(address), current + 1, Opt.some(current)
  )

proc trackCodeChange*(
    tracker: BlockAccessListTrackerRef, address: Address, newCode: seq[byte]
) =
  assert tracker.hasPendingCallFrame()
  let idx = tracker.accountEntry(address)
  template e(): untyped =
    tracker.accounts[idx]

  if e.codeWritten and tracker.codeAt(e.postCode) == newCode:
    return # nothing to do because we have already tracked this value

  tracker.touch(idx)
  tracker.capturePreCode(idx)
  tracker.journal.add(
    JournalEntry(kind: jCode, idx: idx, prevWritten: e.codeWritten, prevCode: e.postCode)
  )
  e.postCode = tracker.addCode(newCode)
  e.codeWritten = true

proc trackSelfDestruct*(tracker: BlockAccessListTrackerRef, address: Address) =
  tracker.trackBalanceChange(address, 0.u256)

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

  for idx in 0 ..< tracker.storage.len:
    template e(): untyped =
      tracker.storage[idx]

    if e.written and (e.pre == e.post or tracker.accounts[e.account].selfDestructed):
      e.written = false
      e.read = true

  for idx in 0 ..< tracker.accounts.len:
    template e(): untyped =
      tracker.accounts[idx]

    if e.balanceWritten and e.preBalance == e.postBalance:
      e.balanceWritten = false
    if e.nonceWritten and e.preNonce == e.postNonce:
      e.nonceWritten = false
    if e.codeWritten and tracker.codeAt(e.preCode) == tracker.codeAt(e.postCode):
      e.codeWritten = false

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
    of jCode:
      tracker.accounts[entry.idx].postCode = entry.prevCode
      tracker.accounts[entry.idx].codeWritten = entry.prevWritten
    of jSelfDestruct:
      tracker.accounts[entry.idx].selfDestructed = false
  tracker.journal.setLen(int(mark.journalLen))

proc rollbackCallFrame*(tracker: BlockAccessListTrackerRef, rollbackReads = false) =
  ## Revert the current call frame. As specified in EIP-7928 the frame's
  ## storage writes become reads and its touched addresses remain. With
  ## `rollbackReads`, which is only meaningful for the transaction frame of a
  ## transaction that is dropped altogether, the transaction leaves no trace.
  doAssert tracker.hasPendingCallFrame()

  if rollbackReads:
    doAssert not tracker.hasParentCallFrame(),
      "reads can only be rolled back for the transaction frame"
    tracker.clearTransaction()
    return

  tracker.undoJournal(tracker.frames[^1])
  tracker.frames.setLen(tracker.frames.len - 1)

# ------------------------------------------------------------------------------
# Inspection
# ------------------------------------------------------------------------------

func isTouched*(tracker: BlockAccessListTrackerRef, address: Address): bool =
  ## Whether the address has been accessed in the current transaction.
  let idx = tracker.findAccount(address)
  idx >= 0 and tracker.accounts[idx].touched

func hasStorageRead*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): bool =
  let idx = tracker.findStorage((address, slot))
  idx >= 0 and tracker.storage[idx].read

func storageChange*(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): Opt[UInt256] =
  ## The pending storage write for the slot in the current transaction.
  let idx = tracker.findStorage((address, slot))
  if idx >= 0 and tracker.storage[idx].written:
    Opt.some(tracker.storage[idx].post)
  else:
    Opt.none(UInt256)

func balanceChange*(tracker: BlockAccessListTrackerRef, address: Address): Opt[UInt256] =
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].balanceWritten:
    Opt.some(tracker.accounts[idx].postBalance)
  else:
    Opt.none(UInt256)

func nonceChange*(
    tracker: BlockAccessListTrackerRef, address: Address
): Opt[AccountNonce] =
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].nonceWritten:
    Opt.some(tracker.accounts[idx].postNonce)
  else:
    Opt.none(AccountNonce)

func codeChange*(tracker: BlockAccessListTrackerRef, address: Address): Opt[seq[byte]] =
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].codeWritten:
    Opt.some(tracker.codeAt(tracker.accounts[idx].postCode))
  else:
    Opt.none(seq[byte])

proc getBlockAccessList*(
    tracker: BlockAccessListTrackerRef, rebuild = false
): lent Opt[BlockAccessListRef] =
  if rebuild or tracker.blockAccessList.isNone():
    tracker.blockAccessList = Opt.some(tracker.builder[].buildBlockAccessList())

  tracker.blockAccessList
