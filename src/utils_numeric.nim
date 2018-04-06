# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ttmath, constants, strformat, strutils, sequtils, endians, macros, utils / padding, rlp

# some methods based on py-evm utils/numeric

# TODO improve

proc intToBigEndian*(value: UInt256): Bytes =
  result = repeat(0.byte, 32)
  for z in 0 ..< 4:
    var temp = value.table[z]
    bigEndian64(result[24 - z * 8].addr, temp.addr)

proc bigEndianToInt*(value: Bytes): UInt256 =
  var bytes = value.padLeft(32, 0.byte)
  result = 0.u256
  for z in 0 ..< 4:
    var temp = 0.uint
    bigEndian64(temp.addr, bytes[24 - z * 8].addr)
    result.table[z] = temp

#echo intToBigEndian("32482610168005790164680892356840817100452003984372336767666156211029086934369".u256)

proc bitLength*(value: UInt256): int =
  var b = ""
  for z in 0 ..< 4:
    b.add(value.table[3 - z].int64.toBin(64))
  result = b.strip(chars={'0'}, trailing=false).len

#proc log256*(value: UInt256): UInt256 =
#  log2(value) div 8

proc ceil8*(value: int): int =
  let remainder = value mod 8
  if remainder == 0:
    value
  else:
    value + 8 - remainder

proc unsignedToSigned*(value: UInt256): Int256 =
  0.i256
  # TODO
  # if value <= UINT_255_MAX_INT:
  #   return value
  # else:
  #   return value - UINT_256_CEILING_INT

proc signedToUnsigned*(value: Int256): UInt256 =
  0.u256
  # TODO
  # if value < 0:
  #   return value + UINT_256_CEILING_INT
  # else:
  #   return value

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
