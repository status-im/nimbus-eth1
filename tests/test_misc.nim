# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  unittest2,
  eth/common/eth_types,
  ../nimbus/evm/internals,
  ../nimbus/core/pow/header

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

    test "calcGasLimitEIP1559":
      type
        GLT = object
          limit: GasInt
          max  : GasInt
          min  : GasInt

      const testData = [
        GLT(limit: 20000000, max: 20019530, min: 19980470),
        GLT(limit: 40000000, max: 40039061, min: 39960939)
      ]

      for x in testData:
        # Increase
        var have = calcGasLimit1559(x.limit, 2*x.limit)
        var want = x.max
        check have == want

        # Decrease
        have = calcGasLimit1559(x.limit, 0)
        want = x.min
        check have == want

        # Small decrease
        have = calcGasLimit1559(x.limit, x.limit-1)
        want = x.limit-1
        check have == want

        # Small increase
        have = calcGasLimit1559(x.limit, x.limit+1)
        want = x.limit+1
        check have == want

        # No change
        have = calcGasLimit1559(x.limit, x.limit)
        want = x.limit
        check have == want

when isMainModule:
  miscMain()
