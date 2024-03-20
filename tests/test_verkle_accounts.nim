# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/algorithm,
  testutils/unittests,
  eth/common,
  stew/byteutils, stint,
  ../nimbus/db/verkle/verkle_accounts

suite "Tree Embeddings Tests":
  test "Test getTreeKey":
    var address: EthAddress
    for i in 0 ..< 10:
      address[1+2*i] = 255
    
    var n = UInt256.one()
    n = n.shl(129)
    n = n + 3

    var tk = getTreeKey(address, n, 1)
    doAssert tk.toHex() == "20f55e0457f368b464533b95c836deb6d6fe1c5a03758bb7732ba6622fddbb01", "Generated trie key is incorrect"

suite "Verkle Account Tests":
  test "Test Verkle Account Updation":
    var trie = newVerkleTrie()

    # Setting the account as per the test vectors by EF
    var acc: Account
    acc.nonce = 32
    acc.balance = UInt256.zero() + 8832
    acc.codeHash = EMPTY_CODE_HASH

    var address: EthAddress = parseAddress("0x3B7C4C2b2b25239E58f8e67509B32edB5bBF293c")

    # Updation of the trie and root commitment calculation
    trie.updateAccount(address, acc)
    var comm = trie.hashVerkleTrie()

    doAssert comm.toHex() == "4f552174cdd1e9a50b03edd879a8f650c7d28e8ab2dd9bd03be45749e4808b34", "Root Commitment not matching with expected data"