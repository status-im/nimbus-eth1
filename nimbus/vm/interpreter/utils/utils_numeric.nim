# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, endians, macros,
  eth_common/eth_types, rlp,
  ../../../constants

# some methods based on py-evm utils/numeric

func bigEndianToInt*(value: openarray[byte]): UInt256 {.inline.}=
  # TODO: delete -> only used int testing
  result.initFromBytesBE(value)

func log256*(value: UInt256): Natural {.inline.}=
  (255 - value.countLeadingZeroBits) shr 3 # div 8

func unsignedToPseudoSigned*(value: UInt256): UInt256 {.inline.}=
  result = value
  if value > INT_256_MAX_AS_UINT256:
    result -= INT_256_MAX_AS_UINT256

func pseudoSignedToUnsigned*(value: UInt256): UInt256 {.inline.}=
  result = value
  if value > INT_256_MAX_AS_UINT256:
    result += INT_256_MAX_AS_UINT256

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
