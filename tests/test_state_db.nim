# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import  unittest2, eth/trie/[hexary, db],
        ../nimbus/db/state_db, stew/byteutils, eth/common,
        stew/ranges

include ../nimbus/db/accounts_cache

proc stateDBMain*() =
  suite "Account State DB":
    setup:
      var
        memDB = newMemoryDB()
        trie = initHexaryTrie(memDB)
        stateDB = newAccountStateDB(memDB, trie.rootHash, true)
        address: EthAddress

      hexToByteArray("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6", address)

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

      var code = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6")
      stateDB.setCode(address, code.toRange)
      stateDB.setNonce(address, 0)
      check stateDB.isDeadAccount(address) == false

      code = @[]
      stateDB.setCode(address, code.toRange)
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
      func initAddr(z: int): EthAddress =
        result[^1] = z.byte

      var ac = init(AccountsCache, memDB, emptyRlpHash, true)
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

      var code = hexToSeqByte("0x0f572e5295c57f15886f9b263e2f6d2d6c7b5ec6").toRange
      ac.setCode(addr1, code)
      check ac.getCode(addr1) == code

      ac.setStorage(addr1, 1.u256, 10.u256)
      check ac.getStorage(addr1, 1.u256) == 10.u256
      check ac.getCommittedStorage(addr1, 1.u256) == 0.u256

      check ac.hasCodeOrNonce(addr1) == true
      check ac.getCodeSize(addr1) == code.len
      
when isMainModule:
  stateDBMain()
