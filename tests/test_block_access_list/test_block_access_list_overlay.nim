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

proc ledgerWithOverlay(
    coreDb: CoreDbRef, bal: BlockAccessListRef, balIndex: int
): LedgerRef =
  ## A fresh ledger over `coreDb`'s base frame with the BAL overlay at `balIndex`.
  result = LedgerRef.init(coreDb.baseTxFrame())
  result.balOverlay = Opt.some(BlockAccessListOverlay.init(bal[].addr, balIndex))

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
      var overlay = BlockAccessListOverlay.init(bal[].addr, 1)
      check:
        not overlay.hasAccount(address1)
        overlay.getAccount(address3) == default(OverlayAccount)
        overlay.getAccount(address2).balance == Opt.some(100.u256)

    block:
      var overlay = BlockAccessListOverlay.init(bal[].addr, 2)
      let acc = overlay.getAccount(address1)
      check:
        acc.balance == Opt.some(11.u256)
        acc.nonce == Opt.some(5.AccountNonce)
        acc.code.isNone()

    block:
      var overlay = BlockAccessListOverlay.init(bal[].addr, 4)
      let acc = overlay.getAccount(address1)
      check:
        acc.balance == Opt.some(33.u256)
        acc.nonce == Opt.some(5.AccountNonce)
        acc.code == Opt.some(code2)

  test "Overlay storage lookup returns the last write below the index":
    var
      overlay1 = BlockAccessListOverlay.init(bal[].addr, 1)
      overlay2 = BlockAccessListOverlay.init(bal[].addr, 2)
      overlay3 = BlockAccessListOverlay.init(bal[].addr, 3)
      overlay4 = BlockAccessListOverlay.init(bal[].addr, 4)

    check:
      overlay1.getStorage(address1, slot1).isNone()
      overlay2.getStorage(address1, slot1) ==
        Opt.some(111.u256)
      overlay3.getStorage(address1, slot1) ==
        Opt.some(111.u256)
      overlay4.getStorage(address1, slot1) ==
        Opt.some(333.u256)
      overlay4.getStorage(address1, slot2).isNone()
      overlay4.getStorage(address1, slot3).isNone()
      overlay4.getStorage(address3, slot1).isNone()

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
      let ledger = ledgerWithOverlay(coreDb, bal, 1)
      check:
        ledger.getBalance(address1) == 1.u256
        ledger.getNonce(address1) == 1.AccountNonce
        ledger.getCode(address1).bytes() == code1
        ledger.getStorage(address1, slot1) == 10.u256
        ledger.getStorage(address1, slot2) == 20.u256
        ledger.getBalance(address2) == 100.u256
        not ledger.accountExists(address4)

    block:
      let ledger = ledgerWithOverlay(coreDb, bal, 2)
      check:
        ledger.getBalance(address1) == 11.u256
        ledger.getNonce(address1) == 5.AccountNonce
        ledger.getCode(address1).bytes() == code1
        ledger.getStorage(address1, slot1) == 111.u256
        ledger.getCommittedStorage(address1, slot1) == 111.u256
        ledger.getStorage(address1, slot2) == 20.u256

    block:
      let ledger = ledgerWithOverlay(coreDb, bal, 4)
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

suite "BAL overlay ledger reads":
  # Each test configures a LedgerRef with a BAL overlay and checks that every
  # read (balance, nonce, code, storage, existence) returns the overlay's
  # pre-state when the BAL has a write *before* the overlay's block access index,
  # and otherwise falls back to the database. Accounts cover: DB-only,
  # overlay-only, in-both, storage-only-in-overlay, and absent-from-both.
  let
    dbAddr = address"0x01007bc31cedb7bfb8a345f31e668033056b2728"
    overlayAddr = address"0x02007bc31cedb7bfb8a345f31e668033056b2728"
    bothAddr = address"0x03007bc31cedb7bfb8a345f31e668033056b2728"
    storageAddr = address"0x04007bc31cedb7bfb8a345f31e668033056b2728"
    absentAddr = address"0x05007bc31cedb7bfb8a345f31e668033056b2728"
    slotA = 1.u256()
    slotB = 2.u256()
    codeDb = @[0x11.byte, 0x22]
    codeOverlay = @[0xaa.byte, 0xbb, 0xcc]

  setup:
    # BAL pre-state writes (blockAccessIndex -> value):
    #   overlayAddr: balance @1=10 @3=30, nonce @1=5, code @2, storage slotA @1=100 @3=300
    #   bothAddr:    balance @2=200, storage slotA @2=2000
    #   storageAddr: storage slotA @1=777
    var builder: BlockAccessListBuilder
    builder.init()
    builder.addBalanceChange(overlayAddr, 1, 10.u256)
    builder.addBalanceChange(overlayAddr, 3, 30.u256)
    builder.addNonceChange(overlayAddr, 1, 5.AccountNonce)
    builder.addCodeChange(overlayAddr, 2, codeOverlay)
    builder.addStorageWrite(overlayAddr, slotA, 1, 100.u256)
    builder.addStorageWrite(overlayAddr, slotA, 3, 300.u256)
    builder.addBalanceChange(bothAddr, 2, 200.u256)
    builder.addStorageWrite(bothAddr, slotA, 2, 2000.u256)
    builder.addStorageWrite(storageAddr, slotA, 1, 777.u256)
    let bal = builder.buildBlockAccessList()

    # Pre-block database state.
    let coreDb = newCoreDbRef(DefaultDbMemory)
    block:
      let dbLedger = LedgerRef.init(coreDb.baseTxFrame())
      dbLedger.setBalance(dbAddr, 1.u256)
      dbLedger.setNonce(dbAddr, 1.AccountNonce)
      dbLedger.setCode(dbAddr, codeDb)
      dbLedger.setStorage(dbAddr, slotA, 11.u256)
      dbLedger.setBalance(bothAddr, 99.u256)
      dbLedger.setNonce(bothAddr, 7.AccountNonce)
      dbLedger.setCode(bothAddr, codeDb)
      dbLedger.setStorage(bothAddr, slotA, 999.u256)
      dbLedger.setStorage(bothAddr, slotB, 888.u256)
      dbLedger.persist()

  test "getBalance reads overlay pre-state and falls back to the database":
    block: # index 2
      let ledger = ledgerWithOverlay(coreDb, bal, 2)
      check:
        ledger.getBalance(dbAddr) == 1.u256        # not in BAL -> DB
        ledger.getBalance(overlayAddr) == 10.u256  # last write before 2 (@1)
        ledger.getBalance(bothAddr) == 99.u256     # BAL write @2 not < 2 -> DB
        ledger.getBalance(storageAddr) == 0.u256   # no balance write anywhere
        ledger.getBalance(absentAddr) == 0.u256
    block: # index 4
      let ledger = ledgerWithOverlay(coreDb, bal, 4)
      check:
        ledger.getBalance(dbAddr) == 1.u256
        ledger.getBalance(overlayAddr) == 30.u256  # last write before 4 (@3)
        ledger.getBalance(bothAddr) == 200.u256    # overlay (@2) overrides DB

  test "getNonce reads overlay pre-state and falls back to the database":
    let ledger = ledgerWithOverlay(coreDb, bal, 4)
    check:
      ledger.getNonce(dbAddr) == 1.AccountNonce
      ledger.getNonce(overlayAddr) == 5.AccountNonce  # @1
      ledger.getNonce(bothAddr) == 7.AccountNonce      # no nonce in BAL -> DB
      ledger.getNonce(storageAddr) == 0.AccountNonce
      ledger.getNonce(absentAddr) == 0.AccountNonce

  test "getCode / getCodeHash / getCodeSize read overlay pre-state and fall back":
    block: # index 2 - overlayAddr code is written @2, not yet visible
      let ledger = ledgerWithOverlay(coreDb, bal, 2)
      check:
        ledger.getCode(dbAddr).bytes() == codeDb
        ledger.getCode(overlayAddr).bytes().len == 0
        ledger.getCode(bothAddr).bytes() == codeDb     # no code in BAL -> DB
    block: # index 4 - overlayAddr code now visible
      let ledger = ledgerWithOverlay(coreDb, bal, 4)
      check:
        ledger.getCode(overlayAddr).bytes() == codeOverlay
        ledger.getCodeHash(overlayAddr) == keccak256(codeOverlay)
        ledger.getCodeSize(overlayAddr) == codeOverlay.len
        ledger.getCode(bothAddr).bytes() == codeDb           # still DB
        ledger.getCodeHash(bothAddr) == keccak256(codeDb)

  test "getStorage / getCommittedStorage read overlay pre-state and fall back":
    block: # index 2
      let ledger = ledgerWithOverlay(coreDb, bal, 2)
      check:
        ledger.getStorage(dbAddr, slotA) == 11.u256        # not in BAL -> DB
        ledger.getStorage(overlayAddr, slotA) == 100.u256  # @1
        ledger.getCommittedStorage(overlayAddr, slotA) == 100.u256
        ledger.getStorage(bothAddr, slotA) == 999.u256     # BAL @2 not < 2 -> DB
        ledger.getStorage(bothAddr, slotB) == 888.u256     # not in BAL -> DB
        ledger.getStorage(storageAddr, slotA) == 777.u256  # @1
        ledger.getStorage(absentAddr, slotA) == 0.u256
    block: # index 4
      let ledger = ledgerWithOverlay(coreDb, bal, 4)
      check:
        ledger.getStorage(overlayAddr, slotA) == 300.u256  # last write before 4 (@3)
        ledger.getCommittedStorage(overlayAddr, slotA) == 300.u256
        ledger.getStorage(bothAddr, slotA) == 2000.u256    # overlay @2 overrides DB
        ledger.getStorage(bothAddr, slotB) == 888.u256     # still DB

  test "accountExists reflects overlay pre-state and database presence":
    block: # index 2
      let ledger = ledgerWithOverlay(coreDb, bal, 2)
      check:
        ledger.accountExists(dbAddr)        # in DB
        ledger.accountExists(overlayAddr)   # overlay balance @1
        ledger.accountExists(bothAddr)      # in DB
        ledger.accountExists(storageAddr)   # overlay storage @1
        not ledger.accountExists(absentAddr)
    block: # index 1 - overlay-only accounts have no write before index 1 yet
      let ledger = ledgerWithOverlay(coreDb, bal, 1)
      check:
        ledger.accountExists(dbAddr)
        ledger.accountExists(bothAddr)
        not ledger.accountExists(overlayAddr)
        not ledger.accountExists(storageAddr)
        not ledger.accountExists(absentAddr)

  test "reads select the last write strictly before the block access index":
    # overlayAddr: balance @1=10 @3=30; storage slotA @1=100 @3=300.
    check:
      ledgerWithOverlay(coreDb, bal, 1).getBalance(overlayAddr) == 0.u256
      ledgerWithOverlay(coreDb, bal, 2).getBalance(overlayAddr) == 10.u256
      ledgerWithOverlay(coreDb, bal, 3).getBalance(overlayAddr) == 10.u256 # @3 not < 3
      ledgerWithOverlay(coreDb, bal, 4).getBalance(overlayAddr) == 30.u256
      ledgerWithOverlay(coreDb, bal, 5).getBalance(overlayAddr) == 30.u256
      ledgerWithOverlay(coreDb, bal, 1).getStorage(overlayAddr, slotA) == 0.u256
      ledgerWithOverlay(coreDb, bal, 2).getStorage(overlayAddr, slotA) == 100.u256
      ledgerWithOverlay(coreDb, bal, 3).getStorage(overlayAddr, slotA) == 100.u256
      ledgerWithOverlay(coreDb, bal, 4).getStorage(overlayAddr, slotA) == 300.u256

  test "account absent from the overlay reads entirely from the database":
    let ledger = ledgerWithOverlay(coreDb, bal, 4)
    check:
      ledger.getBalance(dbAddr) == 1.u256
      ledger.getNonce(dbAddr) == 1.AccountNonce
      ledger.getCode(dbAddr).bytes() == codeDb
      ledger.getStorage(dbAddr, slotA) == 11.u256
      ledger.getStorage(dbAddr, slotB) == 0.u256   # unset slot
      ledger.accountExists(dbAddr)

  test "overlay overrides only the fields it has; the database supplies the rest":
    # bothAddr at index 4: overlay supplies balance and storage slotA; nonce and
    # code come from the database.
    let ledger = ledgerWithOverlay(coreDb, bal, 4)
    check:
      ledger.getBalance(bothAddr) == 200.u256          # overlay
      ledger.getStorage(bothAddr, slotA) == 2000.u256  # overlay
      ledger.getNonce(bothAddr) == 7.AccountNonce       # DB
      ledger.getCode(bothAddr).bytes() == codeDb         # DB
      ledger.getStorage(bothAddr, slotB) == 888.u256     # DB

  test "storage-only overlay account is materialised so its storage is read":
    # storageAddr has only a storage write in the BAL and is absent from the DB;
    # hasAccount must still materialise it (exists() on balance/nonce/code alone
    # would miss it, making getStorage wrongly return 0).
    let ledger = ledgerWithOverlay(coreDb, bal, 2)
    check:
      ledger.accountExists(storageAddr)
      ledger.getStorage(storageAddr, slotA) == 777.u256
      ledger.getStorage(storageAddr, slotB) == 0.u256
      ledger.getBalance(storageAddr) == 0.u256
