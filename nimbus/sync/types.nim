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

proc new*(T: type TxHash): T = Hash256().T
proc new*(T: type NodeHash): T = Hash256().T
proc new*(T: type BlockHash): T = Hash256().T
proc new*(T: type TrieHash): T = Hash256().T

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

proc read*(rlp: var Rlp, T: type TrieHash): T
    {.gcsafe, raises: [Defect,RlpError]} =
  rlp.read(Hash256).T

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

func toHex*(hash: Hash256): string =
  ## Shortcut for buteutils.toHex(hash.data)
  hash.data.toHex

func `$`*(th: TrieHash|NodeHash): string =
  th.Hash256.toHex

func `$`*(hash: Hash256): string =
  hash.toHex

func `$`*(blob: Blob): string =
  blob.toHex

func `$`*(hashOrNum: HashOrNum): string =
  # It's always obvious which one from the visible length of the string.
  if hashOrNum.isHash: $hashOrNum.hash
  else: $hashOrNum.number

func traceStep*(request: BlocksRequest): string =
  var str = if request.reverse: "-" else: "+"
  if request.skip < high(typeof(request.skip)):
    return str & $(request.skip + 1)
  return static($(high(typeof(request.skip)).u256 + 1))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
