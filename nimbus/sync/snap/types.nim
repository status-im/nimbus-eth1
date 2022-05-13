# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  eth/common/eth_types,
  nimcrypto/keccak

{.push raises: [Defect].}

type
  TxHash* = Hash256
    ## Hash of a transaction.

  NodeHash* = Hash256
    ## Hash of a trie node or other blob carried over `eth.NodeData`:
    ## account trie nodes, storage trie nodes, contract code.

  BlockHash* = Hash256
    ## Hash of a block, goes with `BlockNumber`.

  TrieHash* = Hash256
    ## Hash of a trie root: accounts, storage, receipts or transactions.

proc toNodeHash*(data: Blob): NodeHash =
  keccak256.digest(data).NodeHash

# End
