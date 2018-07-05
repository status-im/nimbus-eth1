# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, strutils, sequtils, endians, macros,
  eth_common/eth_types, rlp,
  ../../constants, ../../utils/padding

# some methods based on py-evm utils/numeric

proc bigEndianToInt*(value: openarray[byte]): UInt256 =
  if value.len == 32:
    readUintBE[256](value)
  else:
    readUintBE[256](padLeft(@value, 32, 0.byte))

proc log256*(value: UInt256): Natural =
  (255 - value.countLeadingZeroBits) div 8 # Compilers optimize to `shr 3`

proc unsignedToPseudoSigned*(value: UInt256): UInt256 =
  result = value
  if value > INT_256_MAX_AS_UINT256:
    result -= INT_256_MAX_AS_UINT256

proc pseudoSignedToUnsigned*(value: UInt256): UInt256 =
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
