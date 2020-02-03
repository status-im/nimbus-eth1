# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, macros, strformat,
  eth/common/eth_types,
  ../nimbus/[vm_types, errors, vm/interpreter]

# TODO: quicktest
# PS: parametrize can be easily immitated, but still quicktests would be even more useful

# disableLogging()

proc initGasMeter(startGas: GasInt): GasMeter = result.init(startGas)

proc gasMeters: seq[GasMeter] =
  @[initGasMeter(10), initGasMeter(100), initGasMeter(999)]

macro all(element: untyped, handler: untyped): untyped =
  let name = ident(&"{element.repr}s")
  let StartGas = ident("StartGas")
  result = quote:
    var res = `name`()
    for `element` in res.mitems:
      let `StartGas` = `element`.gasRemaining
      `handler`

# @pytest.mark.parametrize("value", (0, 10))
# def test_start_gas_on_instantiation(value):
#     meter = GasMeter(value)
#     doAssert meter.start_gas == value
#     doAssert meter.gas_remaining == value
#     doAssert meter.gas_refunded == 0


# @pytest.mark.parametrize("value", (-1, 2**256, 'a'))
# def test_instantiation_invalid_value(value):
#     with pytest.raises(ValidationError):
#         GasMeter(value)


# @pytest.mark.parametrize("amount", (0, 1, 10))
# def test_consume_gas(gas_meter, amount):
#     gas_meter.consume_gas(amount, "reason")
#     doAssert gas_meter.gas_remaining == gas_meter.start_gas - amount


# @pytest.mark.parametrize("amount", (0, 1, 99))
# def test_return_gas(gas_meter, amount):
#     gas_meter.return_gas(amount)
#     doAssert gas_meter.gas_remaining == (gas_meter.start_gas + amount)

# @pytest.mark.parametrize("amount", (0, 1, 99))
# def test_refund_gas(gas_meter, amount):
#     gas_meter.refund_gas(amount)
#     doAssert gas_meter.gas_refunded == amount

proc gasMeterMain*() =
  suite "gasMeter":
    # types
    # test "consume rejects negative":
    #   all(gasMeter):
    #     expect(ValidationError):
    #       gasMeter.consumeGas(-1.i256, "independent")

    # test "return rejects negative":
    #   all(gasMeter):
    #     expect(ValidationError):
    #       gasMeter.returnGas(-1.i256)

    # test "refund rejects negative":
    #   all(gasMeter):
    #     expect(ValidationError):
    #       gasMeter.returnGas(-1.i256)

    # TODO: -0/+0
    test "consume spends":
      all(gasMeter):
        check(gasMeter.gasRemaining == StartGas)
        let consume = StartGas
        gasMeter.consumeGas(consume, "0")
        check(gasMeter.gasRemaining - (StartGas - consume) == 0)

    test "consume errors":
      all(gasMeter):
        check(gasMeter.gasRemaining == StartGas)
        expect(OutOfGas):
          gasMeter.consumeGas(StartGas + 1, "")

    test "return refund works correctly":
      all(gasMeter):
        check(gasMeter.gasRemaining == StartGas)
        check(gasMeter.gasRefunded == 0)
        gasMeter.consumeGas(5, "")
        check(gasMeter.gasRemaining == StartGas - 5)
        gasMeter.returnGas(5)
        check(gasMeter.gasRemaining == StartGas)
        gasMeter.refundGas(5)
        check(gasMeter.gasRefunded == 5)

when isMainModule:
  gasMeterMain()
