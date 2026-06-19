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
  stew/byteutils,
  unittest2,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/db/core_db,
  ../../execution_chain/db/ledger,
  ../../execution_chain/block_access_list/[
    block_access_list_builder, block_access_list_overlay, block_access_list_utils]

suite "Block access list overlay":
  let
    address1 = address"0x10007bc31cedb7bfb8a345f31e668033056b2728"
    address2 = address"0x20007bc31cedb7bfb8a345f31e668033056b2728"
    address3 = address"0x30007bc31cedb7bfb8a345f31e668033056b2728"
    address4 = address"0x40007bc31cedb7bfb8a345f31e668033056b2728"
    slot1 = 1.u256()
    slot2 = 2.u256()
    slot3 = 3.u256()
    code1 = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
    code2 = @[0xaa.byte, 0xbb]

  setup:
    var builder: BlockAccessListBuilder
    builder.init()
    builder.addStorageWrite(address1, slot1, 1, 111.u256)
    builder.addStorageWrite(address1, slot1, 3, 333.u256)
    builder.addStorageRead(address1, slot2)
    builder.addBalanceChange(address1, 1, 11.u256)
    builder.addBalanceChange(address1, 3, 33.u256)
    builder.addNonceChange(address1, 1, 5.AccountNonce)
    builder.addCodeChange(address1, 2, code2)
    builder.addBalanceChange(address2, 0, 100.u256)
    builder.addBalanceChange(address2, 2, 200.u256)
    builder.addBalanceChange(address4, 2, 44.u256)
    builder.addNonceChange(address4, 2, 1.AccountNonce)
    builder.addCodeChange(address4, 2, code2)

    let bal = builder.buildBlockAccessList()

  test "Binary search helpers":
    let accPos = bal[].findAccountChanges(address1)
    check:
      accPos >= 0
      bal[].findAccountChanges(address3) == -1
      bal[][accPos].storageChanges.findSlotChanges(slot1) == 0
      bal[][accPos].storageChanges.findSlotChanges(slot3) == -1

    let balanceChanges = bal[][accPos].balanceChanges
    check:
      balanceChanges.findLastWriteBefore(1) == -1
      balanceChanges.findLastWriteBefore(2) == 0
      balanceChanges.findLastWriteBefore(3) == 0
      balanceChanges.findLastWriteBefore(4) == 1

  test "Overlay account lookup returns the last write below the index":
    block:
      let overlay = BlockAccessListOverlay.init(bal[].addr, 1)
      check:
        not overlay.getAccount(address1).exists()
        overlay.getAccount(address3) == default(OverlayAccount)
        overlay.getAccount(address2).balance == Opt.some(100.u256)

    block:
      let
        overlay = BlockAccessListOverlay.init(bal[].addr, 2)
        acc = overlay.getAccount(address1)
      check:
        acc.balance == Opt.some(11.u256)
        acc.nonce == Opt.some(5.AccountNonce)
        acc.code.isNone()

    block:
      let
        overlay = BlockAccessListOverlay.init(bal[].addr, 4)
        acc = overlay.getAccount(address1)
      check:
        acc.balance == Opt.some(33.u256)
        acc.nonce == Opt.some(5.AccountNonce)
        acc.code == Opt.some(code2)

  test "Overlay storage lookup returns the last write below the index":
    check:
      BlockAccessListOverlay.init(bal[].addr, 1).getStorage(address1, slot1).isNone()
      BlockAccessListOverlay.init(bal[].addr, 2).getStorage(address1, slot1) ==
        Opt.some(111.u256)
      BlockAccessListOverlay.init(bal[].addr, 3).getStorage(address1, slot1) ==
        Opt.some(111.u256)
      BlockAccessListOverlay.init(bal[].addr, 4).getStorage(address1, slot1) ==
        Opt.some(333.u256)
      BlockAccessListOverlay.init(bal[].addr, 4).getStorage(address1, slot2).isNone()
      BlockAccessListOverlay.init(bal[].addr, 4).getStorage(address1, slot3).isNone()
      BlockAccessListOverlay.init(bal[].addr, 4).getStorage(address3, slot1).isNone()

  test "Ledger reads through the overlay with database fallback":
    let coreDb = newCoreDbRef(DefaultDbMemory)

    block:
      let dbLedger = LedgerRef.init(coreDb.baseTxFrame())
      dbLedger.setBalance(address1, 1.u256)
      dbLedger.setNonce(address1, 1.AccountNonce)
      dbLedger.setCode(address1, code1)
      dbLedger.setStorage(address1, slot1, 10.u256)
      dbLedger.setStorage(address1, slot2, 20.u256)
      dbLedger.setBalance(address2, 2.u256)
      dbLedger.persist()

    block:
      let ledger = LedgerRef.init(coreDb.baseTxFrame())
      ledger.balOverlay = Opt.some(BlockAccessListOverlay.init(bal[].addr, 1))
      check:
        ledger.getBalance(address1) == 1.u256
        ledger.getNonce(address1) == 1.AccountNonce
        ledger.getCode(address1).bytes() == code1
        ledger.getStorage(address1, slot1) == 10.u256
        ledger.getStorage(address1, slot2) == 20.u256
        ledger.getBalance(address2) == 100.u256
        not ledger.accountExists(address4)

    block:
      let ledger = LedgerRef.init(coreDb.baseTxFrame())
      ledger.balOverlay = Opt.some(BlockAccessListOverlay.init(bal[].addr, 2))
      check:
        ledger.getBalance(address1) == 11.u256
        ledger.getNonce(address1) == 5.AccountNonce
        ledger.getCode(address1).bytes() == code1
        ledger.getStorage(address1, slot1) == 111.u256
        ledger.getCommittedStorage(address1, slot1) == 111.u256
        ledger.getStorage(address1, slot2) == 20.u256

    block:
      let ledger = LedgerRef.init(coreDb.baseTxFrame())
      ledger.balOverlay = Opt.some(BlockAccessListOverlay.init(bal[].addr, 4))
      check:
        ledger.getBalance(address1) == 33.u256
        ledger.getCode(address1).bytes() == code2
        ledger.getCodeHash(address1) == keccak256(code2)
        ledger.getStorage(address1, slot1) == 333.u256
        ledger.accountExists(address4)
        ledger.getBalance(address4) == 44.u256
        ledger.getNonce(address4) == 1.AccountNonce
        ledger.getCode(address4).bytes() == code2
        ledger.getStorage(address4, slot1) == 0.u256
