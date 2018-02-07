import ttmath, constants, strformat, macros

proc intToBigEndian*(value: Int256): string =
  result = ""

proc bigEndianToInt*(value: string): Int256 =
  result = 0.int256

proc unsignedToSigned*(value: Int256): Int256 =
  if value <= UINT_255_MAX:
    return value
  else:
    return value - UINT_256_CEILING

proc signedToUnsigned*(value: Int256): Int256 =
  if value < 0:
    return value + UINT_256_CEILING
  else:
    return value

macro ceilXX(ceiling: static[int]): untyped =
  var name = ident(&"ceil{ceiling}")
  result = quote:
    proc `name`*(value: Int256): Int256 =
      var remainder = value mod `ceiling`.int256
      if remainder == 0:
        return value
      else:
        return value + `ceiling`.int256 - remainder


ceilXX(32)
ceilXX(8)
