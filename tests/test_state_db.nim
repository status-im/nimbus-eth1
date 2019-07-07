# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import  unittest, strutils, eth/trie/[hexary, db],
        ../nimbus/db/state_db, stew/byteutils, eth/common,
        stew/ranges

suite "Account State DB":
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
