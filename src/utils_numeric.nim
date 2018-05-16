# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stint, constants, strformat, strutils, sequtils, endians, macros, utils / padding, rlp

# some methods based on py-evm utils/numeric

# TODO improve

proc intToBigEndian*(value: UInt256): Bytes =
  result = newSeq[byte](32)
  let v_ptr = cast[ptr array[32, byte]](value.unsafeAddr)

  for idx, val in result.mpairs:
    when system.cpuEndian == littleEndian:
      val = v_ptr[32 - 1 - idx]
    else:
      val = v_ptr[idx]

proc bigEndianToInt*(value: Bytes): UInt256 =
  var bytes = value.padLeft(32, 0.byte)
  let v_ptr = cast[ptr array[32, byte]](result.addr)

  for idx, val in bytes:
    when system.cpuEndian == littleEndian:
      v_ptr[32 - 1 - idx] = val
    else:
      v_ptr[idx] = val

#echo intToBigEndian("32482610168005790164680892356840817100452003984372336767666156211029086934369".u256)

# proc bitLength*(value: UInt256): int =
#   255 - value.countLeadingZeroBits

proc log256*(value: UInt256): UInt256 =
  ((255 - value.countLeadingZeroBits) div 8).u256

# proc ceil8*(value: int): int =
#   let remainder = value mod 8
#   if remainder == 0:
#     value
#   else:
#     value + 8 - remainder

proc unsignedToSigned*(value: UInt256): Int256 =
  0.i256
  # TODO Remove stub (used in quasiBoolean for signed comparison)

proc signedToUnsigned*(value: Int256): UInt256 =
  0.u256
  # TODO Remove stub (used in quasiBoolean for signed comparison)

proc unsignedToPseudoSigned*(value: UInt256): UInt256 =
  result = value
  if value > INT_256_MAX_AS_UINT256:
    result -= INT_256_MAX_AS_UINT256

proc pseudoSignedToUnsigned*(value: UInt256): UInt256 =
  result = value
  if value > INT_256_MAX_AS_UINT256:
    result += INT_256_MAX_AS_UINT256

# it's deasible to map nameXX methods like that (originally decorator)
macro ceilXX(ceiling: static[int]): untyped =
  var name = ident(&"ceil{ceiling}")
  result = quote:
    proc `name`*(value: UInt256): UInt256 =
      var remainder = value mod `ceiling`.u256
      if remainder == 0:
        return value
      else:
        return value + `ceiling`.u256 - remainder


ceilXX(32)
ceilXX(8)
