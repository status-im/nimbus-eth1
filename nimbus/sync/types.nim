# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[math, strutils, hashes],
  eth/common/eth_types,
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
# Public constructors
# ------------------------------------------------------------------------------

proc new*(T: type TxHash): T = Hash256().T
proc new*(T: type NodeHash): T = Hash256().T
proc new*(T: type BlockHash): T = Hash256().T
proc new*(T: type TrieHash): T = Hash256().T

# ------------------------------------------------------------------------------
# Public (probably non-trivial) type conversions
# ------------------------------------------------------------------------------

proc to*(num: UInt256; T: type float): T =
  ## Convert to float
  let mantissaLen = 256 - num.leadingZeros
  if mantissaLen <= 64:
    num.truncate(uint64).T
  else:
    let exp = mantissaLen - 64
    (num shr exp).truncate(uint64).T * (2.0 ^ exp)

proc to*(num: SomeInteger; T: type float): T =
  ## Convert to float
  num.T

proc to*(w: TrieHash|NodeHash|BlockHash|TxHash; T: type Hash256): T =
  ## Get rid of `distinct` harness (needed for `snap1` and `eth1` protocol
  ## driver access.)
  w.Hash256

proc to*(w: seq[TrieHash|NodeHash|BlockHash|TxHash]; T: type seq[Hash256]): T =
  ## Ditto
  cast[seq[Hash256]](w)

proc to*(bh: BlockHash; T: type HashOrNum): T =
  ## Convert argument blocj hash `bh` to `HashOrNum`
  T(isHash: true, hash: bh.Hash256)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc read*(rlp: var Rlp, T: type TrieHash): T
    {.gcsafe, raises: [Defect,RlpError]} =
  ## RLP mixin reader
  rlp.read(Hash256).T

proc `==`*(a: NodeHash; b: TrieHash): bool = a.Hash256 == b.Hash256
proc `==`*(a,b: TrieHash): bool {.borrow.}
proc `==`*(a,b: NodeHash): bool {.borrow.}
proc `==`*(a,b: BlockHash): bool {.borrow.}

proc hash*(root: TrieHash|NodeHash|BlockHash): Hash =
  ## Mixin for `Table` or `keyedQueue`
  root.Hash256.data.hash

# ------------------------------------------------------------------------------
# Public printing and pretty printing
# ------------------------------------------------------------------------------

proc toPC*(
    num: float;
    digitsAfterDot: static[int] = 2;
    rounding: static[float] = 5.0
      ): string =
  ## Convert argument number `num` to percent string with decimal precision
  ## stated as argument `digitsAfterDot`. Standard rounding is enabled by
  ## default adjusting the first invisible digit, set `rounding = 0` to disable.
  const
    minDigits = digitsAfterDot + 1
    multiplier = (10 ^ (minDigits + 1)).float
    roundUp = rounding / 10.0
  result = ((num * multiplier) + roundUp).int.intToStr(minDigits) & "%"
  result.insert(".", result.len - minDigits)


func toHex*(hash: Hash256): string =
  ## Shortcut for `byteutils.toHex(hash.data)`
  hash.data.toHex

func `$`*(h: TrieHash|NodeHash|BlockHash|TxHash): string =
  $h.Hash256.data.toHex

func `$`*(blob: Blob): string =
  blob.toHex

func `$`*(hashOrNum: HashOrNum): string =
  # It's always obvious which one from the visible length of the string.
  if hashOrNum.isHash: $hashOrNum.hash
  else: $hashOrNum.number

# ------------------------------------------------------------------------------
# Public debug printing helpers
# ------------------------------------------------------------------------------

func traceStep*(request: BlocksRequest): string =
  var str = if request.reverse: "-" else: "+"
  if request.skip < high(typeof(request.skip)):
    return str & $(request.skip + 1)
  return static($(high(typeof(request.skip)).u256 + 1))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
