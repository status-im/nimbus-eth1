# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, endians, macros,
  eth/common/eth_types, eth/rlp,
  ../../../constants

# some methods based on py-evm utils/numeric

func log2*[bits: static int](value: StUint[bits]): Natural {.inline.}=
  (bits - 1) - value.countLeadingZeroBits

func log256*(value: UInt256): Natural {.inline.}=
  value.log2 shr 3 # div 8 (= log2(256), Logb x = Loga x/Loga b)

func ceil32*(value: Natural): Natural {.inline.}=
  # Round input to the nearest bigger multiple of 32

  result = value

  let remainder = result and 31 # equivalent to modulo 32
  if remainder != 0:
    return value + 32 - remainder

func wordCount*(length: Natural): Natural {.inline.}=
  # Returns the number of EVM words corresponding to a specific size.
  # EVM words is rounded up
  length.ceil32 shr 5 # equivalent to `div 32` (32 = 2^5)

proc flipSign(value: var UInt256) =
  # ⚠ Warning: low(Int256) (binary repr 0b1000...0000) cannot be negated, please handle this special case
  value = not value
  value += 1.u256

proc extractSign*(v: var UInt256, sign: var bool) =
  sign = v > INT_256_MAX_AS_UINT256
  if sign:
    flipSign(v)

proc setSign*(v: var UInt256, sign: bool) {.inline.} =
  if sign: flipSign(v)

func cleanMemRef*(x: UInt256): int {.inline.} =
  ## Sanitize memory addresses, catch negative or impossibly big offsets
  # See https://github.com/status-im/nimbus/pull/97 for more info
  # For rationale on shr, see https://github.com/status-im/nimbus/pull/101
  const upperBound = (high(int32) shr 2).u256
  if x > upperBound:
    return high(int32) shr 2
  return x.toInt

proc rangeToPadded*[T: StUint](x: openarray[byte], first, last: int): T =
  ## Convert take a slice of a sequence of bytes interpret it as the big endian
  ## representation of an Uint256. Use padding for sequence shorter than 32 bytes
  ## including 0-length sequences.

  let lo = max(0, first)
  let hi = min(min(x.high, last), (lo+T.bits div 8)-1)

  if not(lo <= hi):
    return # 0

  result = T.fromBytesBE(
    x.toOpenArray(lo, hi),
    allowPadding = true
  )
