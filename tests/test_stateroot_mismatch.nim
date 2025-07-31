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
  stew/byteutils,
  unittest2,
  ../execution_chain/db/ledger,
  ../execution_chain/common/common

suite "Stateroot Mismatch Checks":

  setup:
    let
      memDB = DefaultDbMemory.newCoreDbRef()
      addr1 = address"0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6"
      addr2 = address"0x1f572e5295c57f15886f9b263e2f6d2d6c7b5ec7"
      addr3 = address"0x2f572e5295c57f15886f9b263e2f6d2d6c7b5ec8"
      code = hexToSeqByte("0x010203")
      slot1 = 1.u256
      slot2 = 2.u256
      slot3 = 3.u256

  test "Stateroot check - Accounts":

    # Persist first update to database - changes from a single checkpoint
    let txFrame0 = memDB.baseTxFrame().txFrameBegin()
    block:
      let ac0 = LedgerRef.init(txFrame0, false)
      ac0.setBalance(addr3, 300.u256)
      ac0.persist(clearCache = true)
      txFrame0.checkpoint(1.BlockNumber, skipSnapshot = false)
      memDB.persist(txFrame0, Opt.none(Hash32))


    # Persist second update to database - changes from two checkpoints
    let txFrame1 = memDB.baseTxFrame().txFrameBegin()
    block:
      let
        ac1 = LedgerRef.init(txFrame1, false)
        preStateRoot = ac1.getStateRoot()

      ac1.addBalance(addr1, 50.u256)
      ac1.persist(clearCache = true)
      txFrame1.checkpoint(2.BlockNumber, skipSnapshot = false)

      let postStateRoot = ac1.getStateRoot()
      check preStateRoot != postStateRoot

    let txFrame2 = txFrame1.txFrameBegin()
    block:
      let
        ac2 = LedgerRef.init(txFrame2, false)
        preStateRoot = ac2.getStateRoot()

      ac2.addBalance(addr2, 200.u256)
      ac2.persist(clearCache = true)
      txFrame2.checkpoint(3.BlockNumber, skipSnapshot = false)
      memDB.persist(txFrame2, Opt.none(Hash32))

      let postStateRoot = ac2.getStateRoot()
      check preStateRoot != postStateRoot


    # Persist third update to database - changes from two checkpoints
    let txFrame3 = memDB.baseTxFrame().txFrameBegin()
    block:
      let
        ac3 = LedgerRef.init(txFrame3, false)
        preStateRoot = ac3.getStateRoot()

      ac3.addBalance(addr1, 50.u256)
      ac3.persist(clearCache = true)
      txFrame3.checkpoint(4.BlockNumber, skipSnapshot = false)
      memDB.persist(txFrame3, Opt.none(Hash32))

      let postStateRoot = ac3.getStateRoot()
      check:
        preStateRoot != postStateRoot

        # Check balances
        ac3.getBalance(addr1) == 100.u256
        ac3.getBalance(addr2) == 200.u256
        ac3.getBalance(addr3) == 300.u256

  test "Stateroot check - Storage Slots":

    # Persist first update to database - changes from a single checkpoint
    let txFrame0 = memDB.baseTxFrame().txFrameBegin()
    block:
      let ac0 = LedgerRef.init(txFrame0, false)
      ac0.setBalance(addr1, 0.u256)
      ac0.setCode(addr1, code)
      ac0.setStorage(addr1, slot3, 300.u256)
      ac0.persist(clearCache = true)
      txFrame0.checkpoint(1.BlockNumber, skipSnapshot = false)
      memDB.persist(txFrame0, Opt.none(Hash32))


    # Persist second update to database - changes from two checkpoints
    let txFrame1 = memDB.baseTxFrame().txFrameBegin()
    block:
      let
        ac1 = LedgerRef.init(txFrame1, false)
        preStateRoot = ac1.getStateRoot()

      discard ac1.getStorage(addr1, slot1)
      ac1.setStorage(addr1, slot1, 50.u256)
      ac1.persist(clearCache = true)
      txFrame1.checkpoint(2.BlockNumber, skipSnapshot = false)

      let postStateRoot = ac1.getStateRoot()
      check preStateRoot != postStateRoot

    let txFrame2 = txFrame1.txFrameBegin()
    block:
      let
        ac2 = LedgerRef.init(txFrame2, false)
        preStateRoot = ac2.getStateRoot()

      ac2.setStorage(addr1, slot2, 200.u256)
      ac2.persist(clearCache = true)
      txFrame2.checkpoint(3.BlockNumber, skipSnapshot = false)
      memDB.persist(txFrame2, Opt.none(Hash32))

      let postStateRoot = ac2.getStateRoot()
      check preStateRoot != postStateRoot


    # Persist third update to database - changes from two checkpoints
    let txFrame3 = memDB.baseTxFrame().txFrameBegin()
    block:
      let
        ac3 = LedgerRef.init(txFrame3, false)
        preStateRoot = ac3.getStateRoot()

      let slotValue = ac3.getStorage(addr1, slot1)
      ac3.setStorage(addr1, slot1, slotValue + 50.u256)
      ac3.persist(clearCache = true)
      txFrame3.checkpoint(4.BlockNumber, skipSnapshot = false)
      memDB.persist(txFrame3, Opt.none(Hash32))

      let postStateRoot = ac3.getStateRoot()
      check:
        preStateRoot != postStateRoot
        # Check slots
        ac3.getStorage(addr1, slot1) == 100.u256
        ac3.getStorage(addr1, slot2) == 200.u256
        ac3.getStorage(addr1, slot3) == 300.u256
