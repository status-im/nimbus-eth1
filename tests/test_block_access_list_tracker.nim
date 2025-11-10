# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.used.}

import
  std/tables,
  unittest2,
  ../execution_chain/db/core_db,
  ../execution_chain/block_access_list/block_access_list_tracker


suite "Block access list tracker":
  const
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()
    balance1 = 10.u256()
    balance2 = 20.u256()
    balance3 = 30.u256()

  setup:
    let
      coreDb = newCoreDbRef(DefaultDbMemory)
      ledger = LedgerRef.init(coreDb.baseTxFrame())
      builder = BlockAccessListBuilderRef.init()
      tracker = StateChangeTrackerRef.init(ledger.ReadOnlyLedger, builder)

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
      tracker.trackBalanceChange(address1, balance1)

      check builder.accounts.contains(address1)
      builder.accounts.withValue(address1, accData):
        check accData[].balanceChanges.contains(balIndex)
      do:
        raiseAssert("AccountData should exist")

  test "Set invalid block access index":
    let balIndexes = [
      uint16.low.int - 1,
      uint16.high.int + 1
    ]

    for balIndex in balIndexes:
      expect AssertionDefect:
        tracker.setBlockAccessIndex(balIndex)
