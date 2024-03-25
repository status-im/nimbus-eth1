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

  test "Chunkify Code Simple":
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

  test "Chunkify Code Testnet":
    let code = hexToSeqByte("0x6080604052348015600f57600080fd5b506004361060285760003560e01c806381ca91d314602d575b600080fd5b60336047565b604051603e9190605a565b60405180910390f35b60005481565b6054816073565b82525050565b6000602082019050606d6000830184604d565b92915050565b600081905091905056fea264697066735822122000382db0489577c1646ea2147a05f92f13f32336a32f1f82c6fb10b63e19f04064736f6c63430008070033")
    let chunks = chunkifyCode(code)

    doAssert chunks.len == 32*((code.len div 31) + 1), "Invalid chunk lengths"
    doAssert chunks[0] == byte(0), "Invalid offset in first chunk"

    for i in countup(32, chunks.len-1, 32):
      let chunk = chunks[i..32+i-1]
      if i == 5*32:
        echo chunk.toHex()
        echo chunk[0]
      doAssert not (chunk[0] != byte(0) and i != 5*32), "Invalid offset in chunk"
      doAssert not (i == 4 and chunk[0] != byte(12)), "Invalid offset in chunk"

    let code2 = hexToSeqByte("0x608060405234801561001057600080fd5b506004361061002b5760003560e01c8063f566852414610030575b600080fd5b61003861004e565b6040516100459190610146565b60405180910390f35b6000600160009054906101000a900473ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff166381ca91d36040518163ffffffff1660e01b815260040160206040518083038186803b1580156100b857600080fd5b505afa1580156100cc573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906100f0919061010a565b905090565b60008151905061010481610170565b92915050565b6000602082840312156101205761011f61016b565b5b600061012e848285016100f5565b91505092915050565b61014081610161565b82525050565b600060208201905061015b6000830184610137565b92915050565b6000819050919050565b600080fd5b61017981610161565b811461018457600080fd5b5056fea2646970667358221220d8add45a339f741a94b4fe7f22e101b560dc8a5874cbd957a884d8c9239df86264736f6c63430008070033")
    let chunks2 = chunkifyCode(code2)

    doAssert chunks2.len == 32*((code2.len+30) div 31), "invalid length in chunked data"
    doAssert chunks[0] == byte(0), "invalid offset in first chunk"

    var expected = @[byte(0), 1, 0, 13, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3]
    for i in countup(32, chunks2.len-1, 32):
      let chunk = chunks2[i..32+i-1]
      doAssert chunk[0] == expected[i div 32 - 1], "Invalid chunk"

    let code3 = hexToSeqByte("0x6080604052348015600f57600080fd5b506004361060285760003560e01c8063ab5ed15014602d575b600080fd5b60336047565b604051603e9190605d565b60405180910390f35b60006001905090565b6057816076565b82525050565b6000602082019050607060008301846050565b92915050565b600081905091905056fea2646970667358221220163c79eab5630c3dbe22f7cc7692da08575198dda76698ae8ee2e3bfe62af3de64736f6c63430008070033")
    let chunk3 = chunkifyCode(code3)

    doAssert chunk3.len == 32*((code3.len+30) div 31), "invalid length in chunked data"
    let expected3 = @[byte(0), 0, 0, 0, 13]
    for i in countup(32, chunk3.len-1, 32):
      let chunk = chunk3[i..32+i-1]
      doAssert chunk[0] == expected3[i div 32 - 1], "Invalid chunk"

