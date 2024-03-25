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
  ../nimbus/evm/interpreter/op_codes,
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

  test "Chunkify Code":
    let
      PUSH4 = byte(0x63)
      PUSH3 = byte(0x62)
      PUSH21 = byte(0x74)
      PUSH7 = byte(0x66)
      PUSH30 = byte(0x7d)

    var code = @[byte(0), PUSH4, 1, 2, 3, 4, PUSH3, 58, 68, 12, PUSH21, 1, 2, 3, 4, 5, 6,
      7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
      # Second 31 bytes
      0, PUSH21, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
      PUSH7, 1, 2, 3, 4, 5, 6, 7,
      # # Third 31 bytes
      PUSH30, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
      23, 24, 25, 26, 27, 28, 29, 30
    ]

    echo "code : ", code.toHex()
    echo "----------------------------"
    let chunks = chunkifyCode(code)
    echo "chunkified code : ", chunks.toHex()
    doAssert chunks.len() == 96, "Expected 96 chunks"
    doAssert chunks[0] == byte(0), "invalid offset in first chunk"
    doAssert chunks[32] == byte(1), "invalid offset in second chunk"
    doAssert chunks[64] == byte(0), "Invalid offset in third chunk"
