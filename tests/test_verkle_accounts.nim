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