# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.push raises: [].}

import
  std/[math, hashes],
  eth/common/eth_types_rlp,
  results,
  stew/byteutils

type
  BlockHash* = distinct Hash256
    ## Hash of a block, goes with `BlockNumber`.
    ##
    ## Note that the `ethXX` protocol driver always uses the
    ## underlying `Hash256` type which needs to be converted to `BlockHash`.

  BlocksRequest* = object
    startBlock*: BlockHashOrNumber
    maxResults*, skip*: uint
    reverse*: bool

# ------------------------------------------------------------------------------
# Public constructors
# ------------------------------------------------------------------------------

proc new*(T: type BlockHash): T =
  default(Hash256).T

# ------------------------------------------------------------------------------
# Public (probably non-trivial) type conversions
# ------------------------------------------------------------------------------

proc to*(num: SomeInteger; T: type float): T =
  ## Convert to float. Result an d argument are not strictly equivalent. Though
  ## sort of `(num.to(float) + 0.5).int == num` might hold in many cases.
  num.T

proc to*(longNum: UInt256; T: type float): T =
  ## Convert to float (see also comment at `num.to(float)`, above.)
  let mantissaLen = 256 - longNum.leadingZeros
  if mantissaLen <= 64:
    longNum.truncate(uint64).T
  else:
    let exp = mantissaLen - 64
    (longNum shr exp).truncate(uint64).T * (2.0 ^ exp)

proc to*(w: BlockHash; T: type Hash256): T =
  ## Syntactic sugar
  w.Hash256

proc to*(w: seq[BlockHash]; T: type seq[Hash256]): T =
  ## Ditto
  cast[seq[Hash256]](w)

proc to*(bh: BlockHash; T: type BlockHashOrNumber): T =
  ## Convert argument blocj hash `bh` to `BlockHashOrNumber`
  T(isHash: true, hash: bh.Hash256)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc read*(rlp: var Rlp, T: type BlockHash): T
    {.gcsafe, raises: [RlpError]} =
  ## RLP mixin reader
  rlp.read(Hash256).T

proc append*(writer: var RlpWriter; h: BlockHash) =
  ## RLP mixin
  append(writer, h.Hash256)

proc `==`*(a: BlockHash; b: Hash256): bool =
  a.Hash256 == b

proc `==`*[T: BlockHash](a,b: T): bool =
  a.Hash256 == b.Hash256

proc hash*(root: BlockHash): Hash =
  ## Mixin for `Table` or `KeyedQueue`
  root.Hash256.data.hash

# ------------------------------------------------------------------------------
# Public printing and pretty printing
# ------------------------------------------------------------------------------

func toHex*(hash: Hash256): string =
  ## Shortcut for `byteutils.toHex(hash.data)`
  hash.data.toHex

func `$`*(h: BlockHash): string =
  $h.Hash256.data.toHex

func `$`*(blob: Blob): string =
  blob.toHex

func `$`*(hashOrNum: BlockHashOrNumber): string =
  # It's always obvious which one from the visible length of the string.
  if hashOrNum.isHash: $hashOrNum.hash
  else: $hashOrNum.number

func toStr*(n: BlockNumber): string =
  ## Pretty print block number, explicitely format with a leading hash `#`
  if n == high(BlockNumber): "high" else:"#" & $n

func toStr*(n: Opt[BlockNumber]): string =
  if n.isNone: "n/a" else: n.get.toStr

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
