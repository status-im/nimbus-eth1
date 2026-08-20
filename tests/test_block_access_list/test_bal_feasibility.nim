# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/sets,
  unittest2,
  ../../execution_chain/constants,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/core_db,
  ../../execution_chain/block_access_list/[bal_tracker, bal_validation]

const
  address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
  address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
  slot1 = 1.u256()
  slot2 = 2.u256()
  slot3 = 3.u256()
  slotValue1 = 100.u256()

proc markObserved(
    declaredReads: var HashSet[(Address, UInt256)],
    tracker: BlockAccessListTrackerRef,
    balIndex: int,
) =
  for key in tracker.builder[].storageAccesses(balIndex):
    declaredReads.excl(key)

suite "Block access list storage read feasibility":
  setup:
    let
      coreDb = newCoreDbRef(DefaultDbMemory)
      ledger = LedgerRef.init(coreDb.baseTxFrame())
      tracker = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger)

    ledger.setStorage(address1, slot1, slotValue1)

  teardown:
    tracker.dispose()

  test "buildDeclaredReadSet collects reads and skips system contracts":
    let bal = new BlockAccessList
    bal[].add(AccountChanges(
      address: address1,
      storageReads: @[slot1, slot2]))
    bal[].add(AccountChanges(
      address: address2,
      storageReads: @[slot1]))
    bal[].add(AccountChanges(
      address: address"0x30007bc31cedb7bfb8a345f31e668033056b2728",
      storageChanges: @[(slot1, @[(1.BlockAccessIndex, 1.u256().StorageValue)])]))
    bal[].add(AccountChanges(
      address: BEACON_ROOTS_ADDRESS,
      storageReads: @[slot1, slot2, slot3]))
    bal[].add(AccountChanges(
      address: WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS,
      storageReads: @[slot1]))

    var declaredReads: HashSet[(Address, UInt256)]
    buildDeclaredReadSet(bal, declaredReads)
    check:
      declaredReads.len() == 3
      (address1, slot1) in declaredReads
      (address1, slot2) in declaredReads
      (address2, slot1) in declaredReads

  test "storageAccesses yields reads and writes of the given index only":
    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.trackStorageWrite(address2, slot2, 2.u256)
    tracker.commitCallFrame()

    tracker.setBlockAccessIndex(2)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address2, slot3)
    tracker.commitCallFrame()

    var accesses1: HashSet[(Address, UInt256)]
    for key in tracker.builder[].storageAccesses(1):
      accesses1.incl(key)
    check accesses1 == [(address1, slot1), (address2, slot2)].toHashSet()

    var accesses2: HashSet[(Address, UInt256)]
    for key in tracker.builder[].storageAccesses(2):
      accesses2.incl(key)
    check accesses2 == [(address2, slot3)].toHashSet()

    var accesses3: HashSet[(Address, UInt256)]
    for key in tracker.builder[].storageAccesses(0):
      accesses3.incl(key)
    check accesses3.len() == 0

  test "Committed reads and writes mark declared reads as observed":
    var declaredReads = [
      (address1, slot1), (address1, slot2), (address2, slot1)].toHashSet()

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.trackStorageWrite(address1, slot2, 2.u256)
    tracker.commitCallFrame()

    declaredReads.markObserved(tracker, 1)
    check declaredReads == [(address2, slot1)].toHashSet()

  test "No-op writes are normalized to reads and mark declared reads":
    var declaredReads = [(address1, slot1)].toHashSet()

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, slotValue1)
    tracker.commitCallFrame()

    declaredReads.markObserved(tracker, 1)
    check declaredReads.len() == 0

  test "Reverted call frames still mark declared reads":
    var declaredReads = [(address1, slot1), (address2, slot2)].toHashSet()

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.trackStorageWrite(address2, slot2, 2.u256)
    tracker.rollbackCallFrame()

    declaredReads.markObserved(tracker, 1)
    check declaredReads.len() == 0

  test "Discarded call frames (rollbackReads) do not mark declared reads":
    var declaredReads = [(address1, slot1)].toHashSet()

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.rollbackCallFrame(rollbackReads = true)

    declaredReads.markObserved(tracker, 1)
    check declaredReads == [(address1, slot1)].toHashSet()

  test "Nested call frames only mark after the top-level frame commits":
    var declaredReads = [(address1, slot1)].toHashSet()

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.commitCallFrame()

    declaredReads.markObserved(tracker, 1)
    check declaredReads.len() == 1

    tracker.commitCallFrame()

    declaredReads.markObserved(tracker, 1)
    check declaredReads.len() == 0

  test "Undeclared and duplicate observations are harmless":
    var declaredReads = [(address1, slot1)].toHashSet()

    tracker.setBlockAccessIndex(1)
    tracker.beginCallFrame()
    tracker.trackStorageRead(address1, slot1)
    tracker.trackStorageRead(address2, slot3)
    tracker.commitCallFrame()

    declaredReads.markObserved(tracker, 1)
    declaredReads.markObserved(tracker, 1)
    check declaredReads.len() == 0

  test "checkStorageReadFeasibility boundary math":
    check:
      checkStorageReadFeasibility(0, 0.GasInt).isOk()
      checkStorageReadFeasibility(0, 1_000_000.GasInt).isOk()
      checkStorageReadFeasibility(5, 5.GasInt * BAL_ITEM_COST).isOk()
      checkStorageReadFeasibility(5, 5.GasInt * BAL_ITEM_COST - 1).isErr()
      checkStorageReadFeasibility(1, 0.GasInt).isErr()
