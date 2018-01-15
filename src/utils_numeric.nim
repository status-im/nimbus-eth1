proc intToBigEndian*(value: int): cstring =
  result = cstring""

proc bigEndianToInt*(value: cstring): int =
  result = 0
