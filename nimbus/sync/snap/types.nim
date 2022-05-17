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
  nimcrypto/keccak,
  stew/byteutils

{.push raises: [Defect].}

type
  TxHash* = distinct Hash256
    ## Hash of a transaction.
    ##
    ## Note that the `ethXX` protocol driver always uses the
    ## underlying `Hash256` type which needs to be converted to `TxHash`.

  NodeHash* = distinct Hash256
    ## Hash of a trie node or other blob carried over `NodeData` account trie
    ## nodes, storage trie nodes, contract code.
    ##
    ## Note that the `ethXX` and `snapXX` protocol drivers always use the
    ## underlying `Hash256` type which needs to be converted to `NodeHash`.

  BlockHash* = distinct Hash256
    ## Hash of a block, goes with `BlockNumber`.
    ##
    ## Note that the `ethXX` protocol driver always uses the
    ## underlying `Hash256` type which needs to be converted to `TxHash`.

  TrieHash* = distinct Hash256
    ## Hash of a trie root: accounts, storage, receipts or transactions.
    ##
    ## Note that the `snapXX` protocol driver always uses the underlying
    ## `Hash256` type which needs to be converted to `TrieHash`.

# ------------------------------------------------------------------------------
# Public Constructor
# ------------------------------------------------------------------------------

proc new*(T: type NodeHash): T = Hash256().T
  
# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc untie*(w: TrieHash|NodeHash|BlockHash): Hash256 =
  ## Get rid of `distinct`  harness, needed for `snap1` and `eth1` protocol
  ## driver access.
  w.Hash256

proc untie*(w: seq[NodeHash|NodeHash]): seq[Hash256] =
  ## Ditto
  cast[seq[Hash256]](w)

proc `==`*(a: NodeHash; b: TrieHash): bool = a.Hash256 == b.Hash256
proc `==`*(a,b: TrieHash): bool {.borrow.}
proc `==`*(a,b: NodeHash): bool {.borrow.}
proc `==`*(a,b: BlockHash): bool {.borrow.}

proc toNodeHash*(data: Blob): NodeHash =
  keccak256.digest(data).NodeHash

proc toHashOrNum*(bh: BlockHash): HashOrNum =
  HashOrNum(isHash: true, hash: bh.Hash256)

# ------------------------------------------------------------------------------
# Public debugging helpers
# ------------------------------------------------------------------------------

proc `$`*(th: TrieHash|NodeHash): string =
  th.Hash256.data.toHex

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
