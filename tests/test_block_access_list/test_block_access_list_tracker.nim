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
  std/[tables, sets],
  stew/byteutils,
  unittest2,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/core_db,
  ../../execution_chain/concurrency/shared_types,
  ../../execution_chain/block_access_list/block_access_list_tracker


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

      check tracker.builder.accounts.contains(address1)
      tracker.builder.accounts.withValue(address1, accData):
        check accData[].balanceChanges.contains(balIndex)

  test "Capture pre balance - stores in preBalanceCache and returns":
    block:
      let cacheKey = address1
      check cacheKey notin tracker.preBalanceCache

      tracker.capturePreBalance(address1)

      check:
        tracker.getPreBalance(address1) == balance1
        cacheKey in tracker.preBalanceCache

    block:
      let cacheKey = address4 # has no balance
      check cacheKey notin tracker.preBalanceCache

      tracker.capturePreBalance(address4)

      check:
        tracker.getPreBalance(address4) == 0.u256
        cacheKey in tracker.preBalanceCache

  test "Capture pre storage - stores in preStorageCache":
    block:
      let cacheKey = (address1, slot1)
      check cacheKey notin tracker.preStorageCache

      tracker.capturePreStorage(address1, slot1)

      check:
        tracker.getPreStorage(address1, slot1) == slotValue1
        cacheKey in tracker.preStorageCache

    block:
      let cacheKey = (address1, slot2)
      check cacheKey notin tracker.preStorageCache

      tracker.capturePreStorage(address1, slot2)

      check:
        tracker.getPreStorage(address1, slot2) == slotValue2
        cacheKey in tracker.preStorageCache

    block:
      let cacheKey = (address2, slot1) # slot doesn't exist
      check cacheKey notin tracker.preStorageCache

      tracker.capturePreStorage(address2, slot1)

      check:
        tracker.getPreStorage(address2, slot1) == 0.u256
        cacheKey in tracker.preStorageCache

  test "Track address access":
    check not tracker.builder.accounts.contains(address1)
    check not tracker.builder.accounts.contains(address2)
    check not tracker.builder.accounts.contains(address4)

    tracker.beginCallFrame()
    tracker.trackAddressAccess(address1)
    tracker.trackAddressAccess(address2)
    tracker.trackAddressAccess(address4)
    tracker.commitCallFrame()

    check tracker.builder.accounts.contains(address1)
    check tracker.builder.accounts.contains(address2)
    check tracker.builder.accounts.contains(address4)

  test "Begin, commit and rollback call frame":
    check tracker.callFrameSnapshots.len() == 0
    tracker.beginCallFrame()
    check tracker.callFrameSnapshots.len() == 1
    tracker.commitCallFrame()
    check tracker.callFrameSnapshots.len() == 0
    tracker.beginCallFrame()
    tracker.beginCallFrame()
    check tracker.callFrameSnapshots.len() == 2
    tracker.rollbackCallFrame()
    check tracker.callFrameSnapshots.len() == 1

  test "Track balance change":
    let
      balIndex = 5
      newBalance = 3000.u256

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    check tracker.callFrameSnapshots.len() == 1

    check not tracker.builder.accounts.contains(address2)
    tracker.trackBalanceChange(address2, newBalance)

    check:
      tracker.pendingCallFrame().balanceChanges.contains(address2)
      tracker.pendingCallFrame().balanceChanges.getOrDefault(address2) == newBalance

    tracker.commitCallFrame()

    check tracker.builder.accounts.contains(address2)
    tracker.builder.accounts.withValue(address2, accData):
      check:
        accData[].balanceChanges.contains(balIndex)
        accData[].balanceChanges.get(balIndex) == Opt.some(newBalance)

  test "Track nonce change":
    let
      balIndex = 2
      newNonce = 3.AccountNonce

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    check tracker.callFrameSnapshots.len() == 1

    check not tracker.builder.accounts.contains(address2)
    tracker.trackNonceChange(address2, newNonce)

    check:
      tracker.pendingCallFrame().nonceChanges.contains(address2)
      tracker.pendingCallFrame().nonceChanges.getOrDefault(address2) == newNonce

    tracker.commitCallFrame()

    check tracker.builder.accounts.contains(address2)
    tracker.builder.accounts.withValue(address2, accData):
      check:
        accData[].nonceChanges.contains(balIndex)
        accData[].nonceChanges.get(balIndex) == Opt.some(newNonce)

  test "Track code change":
    let
      balIndex = 10
      newCode = @[0x4.byte, 0x5, 0x6]

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    check tracker.callFrameSnapshots.len() == 1

    check not tracker.builder.accounts.contains(address2)
    tracker.trackCodeChange(address2, newCode)

    check:
      tracker.pendingCallFrame().codeChanges.contains(address2)
      tracker.pendingCallFrame().codeChanges.getOrDefault(address2) == newCode

    tracker.commitCallFrame()

    check tracker.builder.accounts.contains(address2)
    # codeChanges values are SharedBytes (shared heap), which cannot be copied
    # out, so view them in place and compare the bytes via data.
    var hasCode = false
    var codeBytes: seq[byte]
    tracker.builder.accounts.withValue(address2, accData):
      accData[].codeChanges.withValue(balIndex, sharedCode):
        hasCode = true
        codeBytes = sharedCode[].data()
    check:
      hasCode
      codeBytes == newCode

  test "Track storage read":
    block:
      check not tracker.builder.accounts.contains(address1)

      tracker.beginCallFrame()
      tracker.trackStorageRead(address1, slot1)
      tracker.commitCallFrame()

      check tracker.builder.accounts.contains(address1)
      tracker.builder.accounts.withValue(address1, accData):
        check:
          accData[].storageReads.contains(slot1)

    block:
      check not tracker.builder.accounts.contains(address2)

      tracker.beginCallFrame()
      tracker.trackStorageRead(address2, slot2)
      tracker.commitCallFrame()

      check tracker.builder.accounts.contains(address2)
      tracker.builder.accounts.withValue(address2, accData):
        check:
          accData[].storageReads.contains(slot2)

  test "Track storage write - pre-state value not equal to post state value":
    let
      balIndex = 1
      preStateValue = slotValue1
      postStateValue = 100_000.u256

    check:
      not tracker.builder.accounts.contains(address1)
      (address1, slot1) notin tracker.preStorageCache

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, postStateValue)

    check:
      tracker.pendingCallFrame().storageChanges.contains((address1, slot1))
      tracker.pendingCallFrame().storageChanges.getOrDefault((address1, slot1)) == postStateValue

    tracker.commitCallFrame()

    check:
      tracker.builder.accounts.contains(address1)
      (address1, slot1) in tracker.preStorageCache
      tracker.preStorageCache.getOrDefault((address1, slot1)) == preStateValue

    tracker.builder.accounts.withValue(address1, accData):
      check accData[].storageChanges.contains(slot1)
      accData[].storageChanges.withValue(slot1, slotChanges):
        slotChanges[].withValue(balIndex, slotValue):
          check slotValue[] == postStateValue

  test "Track storage write - pre-state value is equal to post state value":
    let
      balIndex = 5
      preStateValue = 0.u256
      postStateValue = 0.u256

    check:
      not tracker.builder.accounts.contains(address2)
      (address2, slot2) notin tracker.preStorageCache

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address2, slot2, postStateValue)

    check tracker.pendingCallFrame().storageChanges.contains((address2, slot2))

    tracker.commitCallFrame()

    check:
      tracker.builder.accounts.contains(address2)
      (address2, slot2) in tracker.preStorageCache
      tracker.preStorageCache.getOrDefault((address2, slot2)) == preStateValue

    tracker.builder.accounts.withValue(address2, accData):
      check:
        not accData[].storageChanges.contains(slot2)
        accData[].storageReads.contains(slot2)

  test "Handle in transaction self destruct":
    let balIndex = 10

    check not tracker.builder.accounts.contains(address1)

    tracker.setBlockAccessIndex(balIndex)
    tracker.beginCallFrame()
    tracker.trackStorageWrite(address1, slot1, 200_000.u256)
    tracker.trackBalanceChange(address1, balance1 + 2.u256)
    tracker.trackNonceChange(address1, 200.AccountNonce)
    tracker.trackCodeChange(address1, @[0x123.byte])

    check:
      tracker.pendingCallFrame().storageChanges.contains((address1, slot1))
      tracker.pendingCallFrame().balanceChanges.contains(address1)
      tracker.pendingCallFrame().nonceChanges.contains(address1)
      tracker.pendingCallFrame().codeChanges.contains(address1)

    tracker.handleInTransactionSelfDestruct(address1)

    check:
      not tracker.pendingCallFrame().storageChanges.contains((address1, slot1))
      tracker.pendingCallFrame().balanceChanges.contains(address1)
      not tracker.pendingCallFrame().nonceChanges.contains(address1)
      not tracker.pendingCallFrame().codeChanges.contains(address1)

    tracker.commitCallFrame()

    check tracker.builder.accounts.contains(address1)
    tracker.builder.accounts.withValue(address1, accData):
      # Compute codeChanges membership separately: a `notin` inside `check`
      # would try to stringify the Table[int, SharedBytes], which is non-copyable.
      let hasCodeChange = balIndex in accData[].codeChanges
      check:
        slot1 notin accData[].storageChanges
        slot1 in accData[].storageReads
        balIndex in accData[].balanceChanges
        balIndex notin accData[].nonceChanges
        not hasCodeChange

  test "tracker owns and frees a builder it allocated":
    let before = getOccupiedSharedMem()
    for _ in 0 ..< 50:
      let owned = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger)
      check owned.builderOwner
      owned.builder[].addTouchedAccount(address1)
      check owned.builder[].accounts.contains(address1)
      owned.dispose()
    check getOccupiedSharedMem() == before

  test "several trackers share one builder without owning it":
    let before = getOccupiedSharedMem()

    var shared = BlockAccessListBuilder.newShared(threadSafe = true)
    let
      t1 = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger, shared)
      t2 = BlockAccessListTrackerRef.init(ledger.ReadOnlyLedger, shared)

    check:
      not t1.builderOwner
      not t2.builderOwner
      t1.builder == shared
      t2.builder == shared

    t1.builder[].addTouchedAccount(address1)
    t2.builder[].addTouchedAccount(address2)
    check:
      shared[].accounts.contains(address1)
      shared[].accounts.contains(address2)

    t1.dispose()
    t2.dispose()
    check:
      shared[].accounts.contains(address1)
      shared[].accounts.contains(address2)

    shared.dispose()
    check getOccupiedSharedMem() == before
