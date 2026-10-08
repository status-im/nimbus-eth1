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
  stew/byteutils,
  unittest2,
  eth/common/[hashes, headers],
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/core_db,
  ../../execution_chain/concurrency/shared_types,
  ../../execution_chain/common/[common, evmforks],
  ../../execution_chain/constants,
  ../../execution_chain/evm/[state, types],
  ../../execution_chain/core/executor/process_transaction,
  ../../execution_chain/block_access_list/bal_tracker

from ../../tools/common/helpers import getChainConfig

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

func noChanges(acc: AccountChanges): bool =
  acc.balanceChanges.len == 0 and acc.nonceChanges.len == 0 and
    acc.codeChanges.len == 0 and acc.storageChanges.len == 0

template inTx(
    tracker: BlockAccessListTrackerRef,
    ledger: LedgerRef,
    balIndex: int,
    doPersist: bool,
    body: untyped,
) =
  tracker.setBlockAccessIndex(balIndex)
  tracker.beginCallFrame()
  block:
    let sp = ledger.beginSavePoint()
    body
    ledger.commit(sp)
  if doPersist:
    ledger.persist(clearEmptyAccount = true)
  tracker.commitCallFrame()

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

    ledger.setBalance(address1, balance1)
    ledger.setNonce(address1, nonce1)
    ledger.setCode(address1, code1)
    ledger.setStorage(address1, slot1, slotValue1)
    ledger.setStorage(address1, slot2, slotValue2)
    ledger.setStorage(address1, slot3, slotValue3)

    ledger.setBalance(address2, balance2)
    ledger.setNonce(address2, nonce2)
    ledger.setCode(address2, code2)

    ledger.setBalance(address3, balance3)
    ledger.setNonce(address3, nonce3)

    ledger.persist()

  teardown:
    tracker.dispose()

  test "Set valid block access index":
    let balIndexes = [uint16.low.int, 1, 10, uint16.high.int - 1, uint16.high.int]

    var expected = balance1
    for balIndex in balIndexes:
      expected = expected + 1.u256
      tracker.inTx(ledger, balIndex, true):
        tracker.trackAddressAccess(address1)
        ledger.setBalance(address1, expected)

      let acc = tracker.buildBal().findAcc(address1)
      check acc.isSome()
      check acc.get().balanceAt(balIndex) == Opt.some(expected)

  test "Track address access":
    tracker.inTx(ledger, 0, true):
      tracker.trackAddressAccess(address1)
      tracker.trackAddressAccess(address2)
      tracker.trackAddressAccess(address4)
      tracker.trackAddressAccess(address1)

    let bal = tracker.buildBal()
    check:
      bal.len == 3
      bal.findAcc(address1).get().noChanges()
      bal.findAcc(address2).get().noChanges()
      bal.findAcc(address4).get().noChanges()
      not bal.hasAccount(address3)

  test "Balance, nonce and code changes":
    let newCode = @[0x4.byte, 0x5, 0x6]
    tracker.inTx(ledger, 5, true):
      tracker.trackAddressAccess(address2)
      ledger.setBalance(address2, 3000.u256)
      ledger.setNonce(address2, nonce2 + 1)
      ledger.setCode(address2, newCode)

    let acc = tracker.buildBal().findAcc(address2)
    check:
      acc.isSome()
      acc.get().balanceAt(5) == Opt.some(3000.u256)
      acc.get().nonceAt(5) == Opt.some(nonce2 + 1)
      acc.get().codeAt(5) == Opt.some(newCode)

  test "Unchanged values are only touched":
    tracker.inTx(ledger, 2, true):
      tracker.trackAddressAccess(address2)
      tracker.trackAddressAccess(address3)
      ledger.setBalance(address2, 1.u256)
      ledger.setBalance(address2, balance2)
      ledger.setCode(address2, code2)
      ledger.addBalance(address3, 0.u256, checkEmptyAccount = false)

    let bal = tracker.buildBal()
    check:
      bal.findAcc(address2).get().noChanges()
      bal.findAcc(address3).get().noChanges()

  test "Storage reads and writes":
    let newValue = 100_000.u256
    tracker.inTx(ledger, 1, true):
      tracker.trackStorageRead(address1, slot1)
      ledger.setStorage(address1, slot1, newValue)
      tracker.trackStorageRead(address2, slot2)
      discard ledger.getStorage(address2, slot2)

    let bal = tracker.buildBal()
    check:
      bal.findAcc(address1).get().storageAt(slot1, 1) == Opt.some(newValue)
      not bal.findAcc(address1).get().hasStorageRead(slot1)
      bal.findAcc(address2).get().hasStorageRead(slot2)
      not bal.findAcc(address2).get().hasStorageChange(slot2)

  test "No-op and round trip storage writes become reads":
    tracker.inTx(ledger, 3, true):
      tracker.trackStorageRead(address1, slot2)
      ledger.setStorage(address1, slot2, slotValue2)
      tracker.trackStorageRead(address1, slot3)
      ledger.setStorage(address1, slot3, 1.u256)
      ledger.setStorage(address1, slot3, slotValue3)

    let acc = tracker.buildBal().findAcc(address1).get()
    check:
      not acc.hasStorageChange(slot2)
      not acc.hasStorageChange(slot3)
      acc.hasStorageRead(slot2)
      acc.hasStorageRead(slot3)

  test "Reverted writes become reads and touches are kept":
    tracker.inTx(ledger, 4, true):
      tracker.trackAddressAccess(address3)
      ledger.setBalance(address3, balance3 + 1.u256)
      let inner = ledger.beginSavePoint()
      tracker.trackStorageRead(address1, slot1)
      ledger.setStorage(address1, slot1, 5.u256)
      tracker.trackAddressAccess(address2)
      ledger.setBalance(address2, 1.u256)
      tracker.trackAddressAccess(address4)
      ledger.setBalance(address4, 7.u256)
      ledger.rollback(inner)

    let bal = tracker.buildBal()
    check:
      bal.findAcc(address3).get().balanceAt(4) == Opt.some(balance3 + 1.u256)
      not bal.findAcc(address1).get().hasStorageChange(slot1)
      bal.findAcc(address1).get().hasStorageRead(slot1)
      bal.findAcc(address2).get().noChanges()
      bal.findAcc(address4).get().noChanges()

  test "Rollback at the top level":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    var sp = ledger.beginSavePoint()
    tracker.trackAddressAccess(address2)
    tracker.trackStorageRead(address1, slot1)
    ledger.setBalance(address2, 1.u256)
    tracker.rollbackCallFrame(rollbackReads = true)
    ledger.rollback(sp)
    ledger.persist()

    check tracker.buildBal().len == 0

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    sp = ledger.beginSavePoint()
    tracker.trackAddressAccess(address2)
    tracker.trackStorageRead(address1, slot1)
    ledger.setBalance(address2, 1.u256)
    tracker.rollbackCallFrame(rollbackReads = false)
    ledger.rollback(sp)
    ledger.persist()

    let bal = tracker.buildBal()
    check:
      bal.findAcc(address2).get().noChanges()
      bal.findAcc(address1).get().hasStorageRead(slot1)

  for persist in [true, false]:
    test "In transaction self destruct, persist = " & $persist:
      let value = 1000.u256
      tracker.inTx(ledger, 10, persist):
        tracker.trackAddressAccess(address4)
        ledger.clearStorage(address4)
        ledger.setNonce(address4, 1)
        ledger.setCode(address4, @[0x60.byte, 0x00])
        ledger.addBalance(address4, value)
        tracker.trackStorageRead(address4, slot1)
        ledger.setStorage(address4, slot1, 9.u256)
        tracker.trackAddressAccess(address3)
        ledger.subBalance(address4, value)
        ledger.addBalance(address3, value)
        check ledger.selfDestruct8246(address4)

      let bal = tracker.buildBal()
      check:
        bal.findAcc(address4).get().noChanges()
        bal.findAcc(address4).get().hasStorageRead(slot1)
        bal.findAcc(address3).get().balanceAt(10) == Opt.some(balance3 + value)

  test "Changes are merged across persists in one window":
    tracker.setBlockAccessIndex(0)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.trackAddressAccess(address2)
    ledger.setStorage(address1, slot1, 5.u256)
    ledger.setBalance(address2, 1.u256)
    ledger.setNonce(address3, 99)
    ledger.persist()
    ledger.setStorage(address1, slot1, slotValue1)
    ledger.setBalance(address2, 2.u256)
    ledger.persist()
    ledger.setStorage(address1, slot2, 6.u256)
    ledger.persist()
    tracker.commitCallFrame()

    let bal = tracker.buildBal()
    check:
      not bal.findAcc(address1).get().hasStorageChange(slot1)
      bal.findAcc(address1).get().hasStorageRead(slot1)
      bal.findAcc(address1).get().storageAt(slot2, 0) == Opt.some(6.u256)
      bal.findAcc(address2).get().balanceAt(0) == Opt.some(2.u256)
      bal.findAcc(address2).get().balanceChanges.len == 1
      bal.findAcc(address3).get().nonceAt(0) == Opt.some(99.AccountNonce)

  test "Touch sets grow and reset per index":
    tracker.inTx(ledger, 1, true):
      for i in 0 ..< 1000:
        tracker.trackAddressAccess(Address.copyFrom(i.u256.toBytesBE, 12))
        tracker.trackStorageRead(address1, i.u256)
    tracker.inTx(ledger, 2, true):
      for i in 0 ..< 1000:
        tracker.trackAddressAccess(Address.copyFrom(i.u256.toBytesBE, 12))

    let bal = tracker.buildBal()
    check:
      bal.len == 1001
      bal.findAcc(address1).get().storageReads.len == 1000

  test "Reinit keeps the owned builder and clears it":
    tracker.inTx(ledger, 1, true):
      tracker.trackAddressAccess(address1)
    check tracker.buildBal().len == 1
    let builder = tracker.builder
    tracker.reinit(ledger.ReadOnlyLedger)
    check:
      tracker.builder == builder
      tracker.buildBal().len == 0

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

suite "Block access list tracker system calls":
  let
    writeInputCode = hexToSeqByte("0x60003560015560025450" & "00")
    writeConstCode = hexToSeqByte("0x600760015500")
    recipient = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    prevHash = hash32"0x1111111111111111111111111111111111111111111111111111111111111111"
    beaconRoot = hash32"0x2222222222222222222222222222222222222222222222222222222222222222"

  setup:
    let
      config = getChainConfig("Amsterdam").expect("Amsterdam config")
      db = newCoreDbRef(DefaultDbMemory)
      com = CommonRef.new(db, config)
      parent = Header(number: 0, timestamp: EthTime(0), gasLimit: 30_000_000.GasInt)
      header = Header(
        number: 1,
        timestamp: EthTime(12),
        gasLimit: 30_000_000.GasInt,
        baseFeePerGas: Opt.some(7.u256),
        excessBlobGas: Opt.some(0'u64),
        slotNumber: Opt.some(1'u64),
      )
      vmState = BaseVMState.new(
        parent, header, com, db.baseTxFrame().txFrameBegin(), enableBalTracker = true)
      tracker = vmState.balTracker

    vmState.ledger.setCode(HISTORY_STORAGE_ADDRESS, writeInputCode)
    vmState.ledger.setCode(BEACON_ROOTS_ADDRESS, writeInputCode)
    vmState.ledger.setCode(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, writeConstCode)
    vmState.ledger.persist()
    tracker.builder[].ensureIndexCount(3, exact = true)

  teardown:
    vmState.dispose()

  test "Pre-execution system calls":
    check vmState.fork >= FkAmsterdam
    tracker.setBlockAccessIndex(0)
    tracker.beginCallFrame()
    vmState.processParentBlockHash(prevHash)
    vmState.processBeaconBlockRoot(beaconRoot)
    tracker.commitCallFrame()

    let bal = tracker.buildBal()
    check:
      bal.findAcc(HISTORY_STORAGE_ADDRESS).get().storageAt(1.u256, 0) ==
        Opt.some(UInt256.fromBytesBE(prevHash.data))
      bal.findAcc(BEACON_ROOTS_ADDRESS).get().storageAt(1.u256, 0) ==
        Opt.some(UInt256.fromBytesBE(beaconRoot.data))
      bal.findAcc(HISTORY_STORAGE_ADDRESS).get().hasStorageRead(2.u256)
      not bal.hasAccount(SYSTEM_ADDRESS)

  test "Post-execution withdrawals and system calls":
    let amount = 5.u256
    tracker.setBlockAccessIndex(2)
    tracker.beginCallFrame()
    tracker.trackAddressAccess(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS)
    vmState.ledger.addBalance(
      WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS, amount, checkEmptyAccount = false)
    tracker.trackAddressAccess(recipient)
    vmState.ledger.addBalance(recipient, 0.u256, checkEmptyAccount = false)
    vmState.ledger.persist(clearEmptyAccount = true)
    check vmState.processDequeueWithdrawalRequests().isOk()
    tracker.commitCallFrame()

    let
      bal = tracker.buildBal()
      requests = bal.findAcc(WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS).get()
    check:
      requests.balanceAt(2) == Opt.some(amount)
      requests.storageAt(1.u256, 2) == Opt.some(7.u256)
      bal.findAcc(recipient).get().noChanges()
      not bal.hasAccount(SYSTEM_ADDRESS)
