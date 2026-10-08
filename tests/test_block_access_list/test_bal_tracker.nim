# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/importutils,
  stew/byteutils,
  unittest2,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/core_db,
  ../../execution_chain/concurrency/shared_types,
  ../../execution_chain/block_access_list/bal_tracker {.all.}

# Inspection of the tracker's pending transaction through its private entries.

privateAccess(BlockAccessListTrackerRef)
privateAccess(AccountEntry)
privateAccess(StorageEntry)
privateAccess(PosTable)

template frameDepth(tracker: BlockAccessListTrackerRef): int =
  tracker.frames.len

func findAccount(tracker: BlockAccessListTrackerRef, address: Address): int32 =
  for i, e in tracker.accounts.entries:
    if e.address == address:
      return int32(i)
  -1

func findStorage(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): int32 =
  for i, e in tracker.storage.entries:
    if e.key.address == address and e.key.slot == slot:
      return int32(i)
  -1

template entryOpt(idx: int32, entry, flag, value: untyped): untyped =
  if idx >= 0 and entry[idx].flag:
    Opt.some(entry[idx].value)
  else:
    Opt.none(typeof(entry[idx].value))

proc capturePreBalance(tracker: BlockAccessListTrackerRef, address: Address) =
  tracker.capturePreBalance(tracker.accountEntry(address))

proc capturePreStorage(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
) =
  tracker.capturePreStorage(tracker.storageEntry((address, slot)))

func preBalance(tracker: BlockAccessListTrackerRef, address: Address): Opt[UInt256] =
  entryOpt(tracker.findAccount(address), tracker.accounts, preBalanceKnown, preBalance)

func preStorage(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): Opt[UInt256] =
  entryOpt(tracker.findStorage(address, slot), tracker.storage, preKnown, pre)

func getPreBalance(tracker: BlockAccessListTrackerRef, address: Address): UInt256 =
  tracker.preBalance(address).valueOr(0.u256)

func getPreStorage(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): UInt256 =
  tracker.preStorage(address, slot).valueOr(0.u256)

func isTouched(tracker: BlockAccessListTrackerRef, address: Address): bool =
  let idx = tracker.findAccount(address)
  idx >= 0 and tracker.accounts[idx].touched

func hasStorageRead(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): bool =
  let idx = tracker.findStorage(address, slot)
  idx >= 0 and tracker.storage[idx].read

func storageChange(
    tracker: BlockAccessListTrackerRef, address: Address, slot: UInt256
): Opt[UInt256] =
  entryOpt(tracker.findStorage(address, slot), tracker.storage, written, post)

func balanceChange(tracker: BlockAccessListTrackerRef, address: Address): Opt[UInt256] =
  entryOpt(tracker.findAccount(address), tracker.accounts, balanceWritten, postBalance)

func nonceChange(
    tracker: BlockAccessListTrackerRef, address: Address
): Opt[AccountNonce] =
  entryOpt(tracker.findAccount(address), tracker.accounts, nonceWritten, postNonce)

func codeChange(tracker: BlockAccessListTrackerRef, address: Address): Opt[seq[byte]] =
  let idx = tracker.findAccount(address)
  if idx >= 0 and tracker.accounts[idx].codeWritten:
    Opt.some(tracker.codeAt(tracker.accounts[idx].postCode))
  else:
    Opt.none(seq[byte])

# The builder no longer exposes its internal storage, so these helpers assert
# against the public BlockAccessList produced by buildBlockAccessList. Building
# is non-consuming, so it can be called repeatedly within a test.

proc buildBal(tracker: BlockAccessListTrackerRef): BlockAccessList =
  tracker.builder[].buildBlockAccessList()[]

func findAcc(bal: BlockAccessList, address: Address): Opt[AccountChanges] =
  for acc in bal:
    if acc.address == address:
      return Opt.some(acc)
  Opt.none(AccountChanges)

func hasAccount(bal: BlockAccessList, address: Address): bool =
  bal.findAcc(address).isSome()

func balanceAt(acc: AccountChanges, balIndex: int): Opt[UInt256] =
  for c in acc.balanceChanges:
    if c.blockAccessIndex == balIndex.BlockAccessIndex:
      return Opt.some(c.postBalance)
  Opt.none(UInt256)

func nonceAt(acc: AccountChanges, balIndex: int): Opt[AccountNonce] =
  for c in acc.nonceChanges:
    if c.blockAccessIndex == balIndex.BlockAccessIndex:
      return Opt.some(c.newNonce)
  Opt.none(AccountNonce)

func codeAt(acc: AccountChanges, balIndex: int): Opt[seq[byte]] =
  for c in acc.codeChanges:
    if c.blockAccessIndex == balIndex.BlockAccessIndex:
      return Opt.some(c.newCode)
  Opt.none(seq[byte])

func storageAt(acc: AccountChanges, slot: UInt256, balIndex: int): Opt[UInt256] =
  for sc in acc.storageChanges:
    if sc.slot == slot:
      for ch in sc.changes:
        if ch.blockAccessIndex == balIndex.BlockAccessIndex:
          return Opt.some(ch.newValue)
  Opt.none(UInt256)

func hasStorageChange(acc: AccountChanges, slot: UInt256): bool =
  for sc in acc.storageChanges:
    if sc.slot == slot:
      return true
  false

func hasStorageRead(acc: AccountChanges, slot: UInt256): bool =
  for r in acc.storageReads:
    if r == slot:
      return true
  false

suite "Block access list tracker":
  let
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    address4 = address"0x40007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()
    slotValue1 = 100.u256()
    slotValue2 = 200.u256()
    slotValue3 = 300.u256()
    balance1 = 10.u256()
    balance2 = 20.u256()
    balance3 = 30.u256()
    nonce1 = 10.AccountNonce
    nonce2 = 11.AccountNonce
    nonce3 = 12.AccountNonce
    code1 = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
    code2 = @[0xaa.byte, 0xbb]

  setup:
    let
      coreDb = newCoreDbRef(DefaultDbMemory)
      ledger = LedgerRef.init(coreDb.baseTxFrame())
      tracker = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger)

    # Setup in test data in db

    # address 1
    ledger.setBalance(address1, balance1)
    ledger.setNonce(address1, nonce1)
    ledger.setCode(address1, code1)
    ledger.setStorage(address1, slot1, slotValue1)
    ledger.setStorage(address1, slot2, slotValue2)
    ledger.setStorage(address1, slot3, slotValue3)

    # address 2
    ledger.setBalance(address2, balance2)
    ledger.setNonce(address2, nonce2)
    ledger.setCode(address2, code2)

    # address 3
    ledger.setBalance(address3, balance3)
    ledger.setNonce(address3, nonce3)

  teardown:
    tracker.dispose()

  test "Set valid block access index":
    let balIndexes = [
      uint16.low.int,
      1,
      10,
      uint16.high.int - 1,
      uint16.high.int
    ]

    for balIndex in balIndexes:
      tracker.setBlockAccessIndex(balIndex)
      tracker.beginCallFrame()
      tracker.trackBalanceChange(address1, balance1 + 1.u256)
      tracker.commitCallFrame()

      let acc = tracker.buildBal().findAcc(address1)
      check acc.isSome()
      check acc.get().balanceAt(balIndex).isSome()

  test "Capture pre balance - stores in preBalanceCache and returns":
    block:
      check tracker.preBalance(address1).isNone()

      tracker.capturePreBalance(address1)

      check:
        tracker.getPreBalance(address1) == balance1
        tracker.preBalance(address1) == Opt.some(balance1)
        not tracker.isTouched(address1)

    block:
      check tracker.preBalance(address4).isNone() # has no balance

      tracker.capturePreBalance(address4)

      check:
        tracker.getPreBalance(address4) == 0.u256
        tracker.preBalance(address4) == Opt.some(0.u256)

  test "Capture pre storage - stores in preStorageCache":
    block:
      check tracker.preStorage(address1, slot1).isNone()

      tracker.capturePreStorage(address1, slot1)

      check:
        tracker.getPreStorage(address1, slot1) == slotValue1
        tracker.preStorage(address1, slot1) == Opt.some(slotValue1)

    block:
      check tracker.preStorage(address1, slot2).isNone()

      tracker.capturePreStorage(address1, slot2)

      check:
        tracker.getPreStorage(address1, slot2) == slotValue2
        tracker.preStorage(address1, slot2) == Opt.some(slotValue2)

    block:
      check tracker.preStorage(address2, slot1).isNone() # slot doesn't exist

      tracker.capturePreStorage(address2, slot1)

      check:
        tracker.getPreStorage(address2, slot1) == 0.u256
        tracker.preStorage(address2, slot1) == Opt.some(0.u256)

  test "Track address access":
    tracker.setBlockAccessIndex(0)

    block:
      let bal = tracker.buildBal()
      check:
        not bal.hasAccount(address1)
        not bal.hasAccount(address2)
        not bal.hasAccount(address4)

    tracker.beginCallFrame()
    tracker.trackAddressAccess(address1)
    tracker.trackAddressAccess(address2)
    tracker.trackAddressAccess(address4)
    tracker.commitCallFrame()

    let bal = tracker.buildBal()
    check:
      bal.hasAccount(address1)
      bal.hasAccount(address2)
      bal.hasAccount(address4)

  test "Begin, commit and rollback call frame":
    check tracker.frameDepth == 0
    tracker.beginCallFrame()
    check tracker.frameDepth == 1
    tracker.commitCallFrame()
    check tracker.frameDepth == 0
    tracker.beginCallFrame()
    tracker.beginCallFrame()
    check tracker.frameDepth == 2
    tracker.rollbackCallFrame()
    check tracker.frameDepth == 1

  test "Track balance change":
    let
      balIndex = 5
      newBalance = 3000.u256

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    check tracker.frameDepth == 1

    check not tracker.buildBal().hasAccount(address2)
    tracker.trackBalanceChange(address2, newBalance)

    check tracker.balanceChange(address2) == Opt.some(newBalance)

    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address2)
    check acc.isSome()
    check acc.get().balanceAt(balIndex) == Opt.some(newBalance)

  test "Track nonce change":
    let
      balIndex = 2
      newNonce = 3.AccountNonce

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    check tracker.frameDepth == 1

    check not tracker.buildBal().hasAccount(address2)
    tracker.trackNonceChange(address2, newNonce)

    check tracker.nonceChange(address2) == Opt.some(newNonce)

    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address2)
    check acc.isSome()
    check acc.get().nonceAt(balIndex) == Opt.some(newNonce)

  test "Track code change":
    let
      balIndex = 10
      newCode = @[0x4.byte, 0x5, 0x6]

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    check tracker.frameDepth == 1

    check not tracker.buildBal().hasAccount(address2)
    tracker.trackCodeChange(address2, newCode)

    check tracker.codeChange(address2) == Opt.some(newCode)

    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address2)
    check acc.isSome()
    check acc.get().codeAt(balIndex) == Opt.some(newCode)

  test "Track storage read":
    tracker.setBlockAccessIndex(0)

    block:
      check not tracker.buildBal().hasAccount(address1)

      tracker.beginCallFrame()
      tracker.trackStorageRead(address1, slot1)
      tracker.commitCallFrame()

      let acc = tracker.buildBal().findAcc(address1)
      check acc.isSome()
      check acc.get().hasStorageRead(slot1)

    block:
      check not tracker.buildBal().hasAccount(address2)

      tracker.beginCallFrame()
      tracker.trackStorageRead(address2, slot2)
      tracker.commitCallFrame()

      let acc = tracker.buildBal().findAcc(address2)
      check acc.isSome()
      check acc.get().hasStorageRead(slot2)

  test "Track storage write - pre-state value not equal to post state value":
    let
      balIndex = 1
      preStateValue = slotValue1
      postStateValue = 100_000.u256

    check:
      not tracker.buildBal().hasAccount(address1)
      tracker.preStorage(address1, slot1).isNone()

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, postStateValue)

    check:
      tracker.storageChange(address1, slot1) == Opt.some(postStateValue)
      tracker.preStorage(address1, slot1) == Opt.some(preStateValue)

    tracker.commitCallFrame()

    check tracker.buildBal().hasAccount(address1)

    let acc = tracker.buildBal().findAcc(address1)
    check acc.isSome()
    check acc.get().storageAt(slot1, balIndex) == Opt.some(postStateValue)

  test "Track storage write - pre-state value is equal to post state value":
    let
      balIndex = 5
      preStateValue = 0.u256
      postStateValue = 0.u256

    check:
      not tracker.buildBal().hasAccount(address2)
      tracker.preStorage(address2, slot2).isNone()

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address2, slot2, postStateValue)

    check:
      tracker.storageChange(address2, slot2) == Opt.some(postStateValue)
      tracker.preStorage(address2, slot2) == Opt.some(preStateValue)

    tracker.commitCallFrame()

    check tracker.buildBal().hasAccount(address2)

    let acc = tracker.buildBal().findAcc(address2)
    check acc.isSome()
    check:
      not acc.get().hasStorageChange(slot2)
      acc.get().hasStorageRead(slot2)

  test "Handle in transaction self destruct":
    let balIndex = 10

    check not tracker.buildBal().hasAccount(address1)

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 200_000.u256)
    tracker.trackBalanceChange(address1, balance1 + 2.u256)
    tracker.trackNonceChange(address1, 200.AccountNonce)
    tracker.trackCodeChange(address1, @[0x123.byte])

    check:
      tracker.storageChange(address1, slot1).isSome()
      tracker.balanceChange(address1).isSome()
      tracker.nonceChange(address1).isSome()
      tracker.codeChange(address1).isSome()

    tracker.trackInTransactionSelfDestruct(address1)
    tracker.trackInTransactionSelfDestruct(address1)

    # resolved at the end of the transaction, not when recorded
    check:
      tracker.storageChange(address1, slot1).isSome()
      tracker.nonceChange(address1) == Opt.some(200.AccountNonce)

    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address1)
    check acc.isSome()
    check:
      not acc.get().hasStorageChange(slot1)
      acc.get().hasStorageRead(slot1)
      acc.get().balanceAt(balIndex).isSome()
      acc.get().nonceAt(balIndex).isSome()
      acc.get().codeAt(balIndex).isSome()
      acc.get().balanceAt(balIndex) == Opt.some(balance1 + 2.u256)

  test "Reverted nested frame turns its writes into reads and restores the parent's":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 11.u256)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 22.u256)
    tracker.trackStorageWrite(address1, slot2, 33.u256)
    tracker.trackBalanceChange(address2, 5.u256)
    tracker.trackNonceChange(address2, 7.AccountNonce)
    tracker.trackCodeChange(address2, @[0x9.byte])
    tracker.trackAddressAccess(address3)
    tracker.trackStorageRead(address2, slot3)
    tracker.rollbackCallFrame()
    check:
      tracker.frameDepth == 1
      tracker.storageChange(address1, slot1) == Opt.some(11.u256)
      tracker.storageChange(address1, slot2).isNone()
      tracker.hasStorageRead(address1, slot2)
      tracker.balanceChange(address2).isNone()
      tracker.nonceChange(address2).isNone()
      tracker.codeChange(address2).isNone()
      tracker.isTouched(address2)
      tracker.isTouched(address3)
      tracker.hasStorageRead(address2, slot3)
    tracker.commitCallFrame()

    let bal = tracker.buildBal()
    let acc1 = bal.findAcc(address1).get()
    check:
      acc1.storageAt(slot1, 1) == Opt.some(11.u256)
      not acc1.hasStorageChange(slot2)
      acc1.hasStorageRead(slot2)
      bal.hasAccount(address3)
    let acc2 = bal.findAcc(address2).get()
    check:
      acc2.hasStorageRead(slot3)
      acc2.balanceAt(1).isNone()
      acc2.nonceAt(1).isNone()
      acc2.codeAt(1).isNone()

  test "A committed child's writes revert together with its parent":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 1.u256)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot2, 2.u256)
    tracker.trackNonceChange(address1, 99.AccountNonce)
    tracker.commitCallFrame()
    check:
      tracker.storageChange(address1, slot2) == Opt.some(2.u256)
      tracker.nonceChange(address1) == Opt.some(99.AccountNonce)
    tracker.rollbackCallFrame()
    check:
      tracker.storageChange(address1, slot1).isNone()
      tracker.hasStorageRead(address1, slot1)
      tracker.storageChange(address1, slot2).isNone()
      tracker.hasStorageRead(address1, slot2)
      tracker.nonceChange(address1).isNone()
    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address1).get()
    check:
      not acc.hasStorageChange(slot1)
      not acc.hasStorageChange(slot2)
      acc.hasStorageRead(slot1)
      acc.hasStorageRead(slot2)
      acc.nonceAt(1).isNone()

  test "Rollback of the transaction frame leaves nothing":
    tracker.setBlockAccessIndex(2)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 5.u256)
    tracker.trackStorageRead(address1, slot2)
    tracker.trackAddressAccess(address2)
    tracker.trackInTransactionSelfDestruct(address1)
    tracker.rollbackCallFrame()
    check:
      tracker.frameDepth == 0
      not tracker.isTouched(address1)
      not tracker.isTouched(address2)
      not tracker.hasStorageRead(address1, slot2)
      tracker.buildBal().len() == 0

  test "Nonce and code changes keep one undo record per frame":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackNonceChange(address1, nonce1 + 1)
    tracker.trackCodeChange(address1, code2)
    tracker.beginCallFrame()
    let mark = tracker.journal.len
    for i in 2 .. 4:
      tracker.trackNonceChange(address1, nonce1 + AccountNonce(i))
      tracker.trackCodeChange(address1, @[byte(i)])
    check tracker.journal.len == mark + 2
    tracker.rollbackCallFrame()
    tracker.beginCallFrame()
    tracker.trackNonceChange(address1, nonce1 + 5)
    tracker.trackCodeChange(address1, @[5.byte])
    tracker.rollbackCallFrame()
    check:
      tracker.nonceChange(address1) == Opt.some(nonce1 + 1)
      tracker.codeChange(address1) == Opt.some(code2)
    tracker.commitCallFrame()

  test "Self-destruct in a reverted frame is discarded":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 1.u256)
    tracker.beginCallFrame()
    tracker.trackInTransactionSelfDestruct(address1)
    tracker.rollbackCallFrame()
    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address1).get()
    check:
      acc.storageAt(slot1, 1) == Opt.some(1.u256)
      acc.nonceAt(1).isNone()
      acc.codeAt(1).isNone()

  test "Self-destruct in a committed frame converts the parent's earlier and later writes":
    tracker.setBlockAccessIndex(2)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 1.u256)
    tracker.beginCallFrame()
    tracker.trackInTransactionSelfDestruct(address1)
    tracker.commitCallFrame()
    tracker.trackStorageWrite(address1, slot2, 2.u256)
    tracker.commitCallFrame()

    let acc = tracker.buildBal().findAcc(address1).get()
    check:
      not acc.hasStorageChange(slot1)
      acc.hasStorageRead(slot1)
      not acc.hasStorageChange(slot2)
      acc.hasStorageRead(slot2)
      acc.nonceAt(2) == Opt.some(0.AccountNonce)
      acc.codeAt(2) == Opt.some(newSeq[byte]())

  test "State is reset between transactions":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 1.u256)
    tracker.trackAddressAccess(address2)
    tracker.commitCallFrame()
    tracker.setBlockAccessIndex(2)
    check:
      not tracker.isTouched(address1)
      not tracker.isTouched(address2)
      tracker.storageChange(address1, slot1).isNone()
      tracker.preStorage(address1, slot1).isNone()
    tracker.beginCallFrame()
    tracker.trackAddressAccess(address3)
    tracker.commitCallFrame()

    let bal = tracker.buildBal()
    check:
      bal.findAcc(address1).get().storageAt(slot1, 1) == Opt.some(1.u256)
      bal.findAcc(address1).get().storageAt(slot1, 2).isNone()
      bal.hasAccount(address3)

  test "tracker owns and frees a builder it allocated":
    let before = getOccupiedSharedMem()
    for _ in 0 ..< 50:
      let owned = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger)
      check owned.builderOwner
      owned.builder[].ensureIndexCount(1)
      owned.builder[].addTouchedAccount(0, address1)
      check owned.builder[].buildBlockAccessList()[].hasAccount(address1)
      owned.dispose()
    check getOccupiedSharedMem() == before

  test "several trackers share one builder without owning it":
    let before = getOccupiedSharedMem()

    var shared = BlockAccessListBuilder.newShared()
    let
      t1 = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger, shared)
      t2 = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger, shared)

    check:
      not t1.builderOwner
      not t2.builderOwner
      t1.builder == shared
      t2.builder == shared

    # Not concurrent: both writes happen on this thread, so a single index
    # partition with one writer at a time is sufficient.
    shared[].ensureIndexCount(1)
    t1.builder[].addTouchedAccount(0, address1)
    t2.builder[].addTouchedAccount(0, address2)
    check:
      shared[].buildBlockAccessList()[].hasAccount(address1)
      shared[].buildBlockAccessList()[].hasAccount(address2)

    t1.dispose()
    t2.dispose()
    check:
      shared[].buildBlockAccessList()[].hasAccount(address1)
      shared[].buildBlockAccessList()[].hasAccount(address2)

    shared.dispose()
    check getOccupiedSharedMem() == before
