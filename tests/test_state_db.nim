# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/trie/trie_defs,
  stew/[byteutils, endians2],
  unittest2,
  ../nimbus/db/state_db

include ../nimbus/db/accounts_cache

func initAddr(z: int): EthAddress =
  const L = sizeof(result)
  result[L-sizeof(uint32)..^1] = toBytesBE(z.uint32)

proc stateDBMain*() =
  suite "Account State DB":
    setup:
      const emptyAcc {.used.} = newAccount()

      var
        memDB = newCoreDbRef LegacyDbMemory
        acDB {.used.} = newCoreDbRef LegacyDbMemory
        trie = memDB.mptPrune()
        stateDB {.used.} = newAccountStateDB(memDB, trie.rootHash, true)
        address {.used.} = hexToByteArray[20]("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
        code {.used.} = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
        rootHash {.used.} : KeccakHash

    test "accountExists and isDeadAccount":
      check stateDB.accountExists(address) == false
      check stateDB.isDeadAccount(address) == true

      var acc = stateDB.getAccount(address)
      acc.balance = 1000.u256
      stateDB.setAccount(address, acc)

      check stateDB.accountExists(address) == true
      check stateDB.isDeadAccount(address) == false

      acc.balance = 0.u256
      acc.nonce = 1
      stateDB.setAccount(address, acc)
      check stateDB.isDeadAccount(address) == false

      stateDB.setCode(address, code)
      stateDB.setNonce(address, 0)
      check stateDB.isDeadAccount(address) == false

      stateDB.setCode(address, [])
      check stateDB.isDeadAccount(address) == true
      check stateDB.accountExists(address) == true

    test "clone storage":
      var x = RefAccount(
        overlayStorage: initTable[UInt256, UInt256](),
        originalStorage: newTable[UInt256, UInt256]()
      )

      x.overlayStorage[10.u256] = 11.u256
      x.overlayStorage[11.u256] = 12.u256

      x.originalStorage[10.u256] = 11.u256
      x.originalStorage[11.u256] = 12.u256

      var y = x.clone(cloneStorage = true)
      y.overlayStorage[12.u256] = 13.u256
      y.originalStorage[12.u256] = 13.u256

      check 12.u256 notin x.overlayStorage
      check 12.u256 in y.overlayStorage

      check x.overlayStorage.len == 2
      check y.overlayStorage.len == 3

      check 12.u256 in x.originalStorage
      check 12.u256 in y.originalStorage

      check x.originalStorage.len == 3
      check y.originalStorage.len == 3

    test "accounts cache":
      var ac = init(AccountsCache, acDB, emptyRlpHash, true)
      var addr1 = initAddr(1)

      check ac.isDeadAccount(addr1) == true
      check ac.accountExists(addr1) == false
      check ac.hasCodeOrNonce(addr1) == false

      ac.setBalance(addr1, 1000.u256)
      check ac.getBalance(addr1) == 1000.u256
      ac.subBalance(addr1, 100.u256)
      check ac.getBalance(addr1) == 900.u256
      ac.addBalance(addr1, 200.u256)
      check ac.getBalance(addr1) == 1100.u256

      ac.setNonce(addr1, 1)
      check ac.getNonce(addr1) == 1
      ac.incNonce(addr1)
      check ac.getNonce(addr1) == 2

      ac.setCode(addr1, code)
      check ac.getCode(addr1) == code

      ac.setStorage(addr1, 1.u256, 10.u256)
      check ac.getStorage(addr1, 1.u256) == 10.u256
      check ac.getCommittedStorage(addr1, 1.u256) == 0.u256

      check ac.hasCodeOrNonce(addr1) == true
      check ac.getCodeSize(addr1) == code.len

      ac.persist()
      rootHash = ac.rootHash

      var db = newAccountStateDB(memDB, emptyRlpHash, true)
      db.setBalance(addr1, 1100.u256)
      db.setNonce(addr1, 2)
      db.setCode(addr1, code)
      db.setStorage(addr1, 1.u256, 10.u256)
      check rootHash == db.rootHash

    test "accounts cache readonly operations":
      # use previous hash
      var ac = init(AccountsCache, acDB, rootHash, true)
      var addr2 = initAddr(2)

      check ac.getCodeHash(addr2) == emptyAcc.codeHash
      check ac.getBalance(addr2) == emptyAcc.balance
      check ac.getNonce(addr2) == emptyAcc.nonce
      check ac.getCode(addr2) == []
      check ac.getCodeSize(addr2) == 0
      check ac.getCommittedStorage(addr2, 1.u256) == 0.u256
      check ac.getStorage(addr2, 1.u256) == 0.u256
      check ac.hasCodeOrNonce(addr2) == false
      check ac.accountExists(addr2) == false
      check ac.isDeadAccount(addr2) == true

      ac.persist()
      # readonly operations should not modify
      # state trie at all
      check ac.rootHash == rootHash

    test "accounts cache code retrieval after persist called":
      var ac = init(AccountsCache, acDB)
      var addr2 = initAddr(2)
      ac.setCode(addr2, code)
      ac.persist()
      check ac.getCode(addr2) == code
      let key = contractHashKey(keccakHash(code))
      check acDB.kvt.get(key.toOpenArray) == code

    test "accessList operations":
      proc verifyAddrs(ac: AccountsCache, addrs: varargs[int]): bool =
        for c in addrs:
          if not ac.inAccessList(c.initAddr):
            return false
        true

      proc verifySlots(ac: AccountsCache, address: int, slots: varargs[int]): bool =
        let a = address.initAddr
        if not ac.inAccessList(a):
            return false

        for c in slots:
          if not ac.inAccessList(a, c.u256):
            return false
        true

      proc accessList(ac: var AccountsCache, address: int) {.inline.} =
        ac.accessList(address.initAddr)

      proc accessList(ac: var AccountsCache, address, slot: int) {.inline.} =
        ac.accessList(address.initAddr, slot.u256)

      var ac = init(AccountsCache, acDB)

      ac.accessList(0xaa)
      ac.accessList(0xbb, 0x01)
      ac.accessList(0xbb, 0x02)
      check ac.verifyAddrs(0xaa, 0xbb)
      check ac.verifySlots(0xbb, 0x01, 0x02)
      check ac.verifySlots(0xaa, 0x01) == false
      check ac.verifySlots(0xaa, 0x02) == false

      var sp = ac.beginSavepoint
      # some new ones
      ac.accessList(0xbb, 0x03)
      ac.accessList(0xaa, 0x01)
      ac.accessList(0xcc, 0x01)
      ac.accessList(0xcc)

      check ac.verifyAddrs(0xaa, 0xbb, 0xcc)
      check ac.verifySlots(0xaa, 0x01)
      check ac.verifySlots(0xbb, 0x01, 0x02, 0x03)
      check ac.verifySlots(0xcc, 0x01)

      ac.rollback(sp)
      check ac.verifyAddrs(0xaa, 0xbb)
      check ac.verifyAddrs(0xcc) == false
      check ac.verifySlots(0xcc, 0x01) == false

      sp = ac.beginSavepoint
      ac.accessList(0xbb, 0x03)
      ac.accessList(0xaa, 0x01)
      ac.accessList(0xcc, 0x01)
      ac.accessList(0xcc)
      ac.accessList(0xdd, 0x04)
      ac.commit(sp)

      check ac.verifyAddrs(0xaa, 0xbb, 0xcc)
      check ac.verifySlots(0xaa, 0x01)
      check ac.verifySlots(0xbb, 0x01, 0x02, 0x03)
      check ac.verifySlots(0xcc, 0x01)
      check ac.verifySlots(0xdd, 0x04)

    test "transient storage operations":
      var ac = init(AccountsCache, acDB)

      proc tStore(ac: AccountsCache, address, slot, val: int) =
        ac.setTransientStorage(address.initAddr, slot.u256, val.u256)

      proc tLoad(ac: AccountsCache, address, slot: int): UInt256 =
        ac.getTransientStorage(address.initAddr, slot.u256)

      proc vts(ac: AccountsCache, address, slot, val: int): bool =
        ac.tLoad(address, slot) == val.u256

      ac.tStore(0xaa, 3, 66)
      ac.tStore(0xbb, 1, 33)
      ac.tStore(0xbb, 2, 99)

      check ac.vts(0xaa, 3, 66)
      check ac.vts(0xbb, 1, 33)
      check ac.vts(0xbb, 2, 99)
      check ac.vts(0xaa, 1, 33) == false
      check ac.vts(0xbb, 1, 66) == false

      var sp = ac.beginSavepoint
      # some new ones
      ac.tStore(0xaa, 3, 77)
      ac.tStore(0xbb, 1, 55)
      ac.tStore(0xcc, 7, 88)

      check ac.vts(0xaa, 3, 77)
      check ac.vts(0xbb, 1, 55)
      check ac.vts(0xcc, 7, 88)

      check ac.vts(0xaa, 3, 66) == false
      check ac.vts(0xbb, 1, 33) == false
      check ac.vts(0xbb, 2, 99)

      ac.rollback(sp)
      check ac.vts(0xaa, 3, 66)
      check ac.vts(0xbb, 1, 33)
      check ac.vts(0xbb, 2, 99)
      check ac.vts(0xcc, 7, 88) == false

      sp = ac.beginSavepoint
      ac.tStore(0xaa, 3, 44)
      ac.tStore(0xaa, 4, 55)
      ac.tStore(0xbb, 1, 22)
      ac.tStore(0xdd, 2, 66)

      ac.commit(sp)
      check ac.vts(0xaa, 3, 44)
      check ac.vts(0xaa, 4, 55)
      check ac.vts(0xbb, 1, 22)
      check ac.vts(0xbb, 1, 55) == false
      check ac.vts(0xbb, 2, 99)
      check ac.vts(0xcc, 7, 88) == false
      check ac.vts(0xdd, 2, 66)

      ac.clearTransientStorage()
      check ac.vts(0xaa, 3, 44) == false
      check ac.vts(0xaa, 4, 55) == false
      check ac.vts(0xbb, 1, 22) == false
      check ac.vts(0xbb, 1, 55) == false
      check ac.vts(0xbb, 2, 99) == false
      check ac.vts(0xcc, 7, 88) == false
      check ac.vts(0xdd, 2, 66) == false

when isMainModule:
  stateDBMain()
