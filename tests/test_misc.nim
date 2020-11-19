import
  unittest2, stew/byteutils,
  eth/common/eth_types,
  ../nimbus/vm/interpreter/utils/utils_numeric

func toAddress(n: int): EthAddress =
  result[19] = n.byte
  
func toAddress(a, b: int): EthAddress =
  result[18] = a.byte
  result[19] = b.byte

func toAddress(a, b, c: int): EthAddress =
  result[17] = a.byte
  result[18] = b.byte
  result[19] = c.byte

proc miscMain*() =
  suite "Misc test suite":
    test "EthAddress to int":
      check toAddress(0xff).toInt == 0xFF
      check toAddress(0x10, 0x0).toInt == 0x1000
      check toAddress(0x10, 0x0, 0x0).toInt == 0x100000

when isMainModule:
  miscMain()
