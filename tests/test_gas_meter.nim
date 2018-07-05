# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, macros, strformat,
  eth_common/eth_types,
  ../nimbus/[vm_types, errors, logging, vm/interpreter]

# TODO: quicktest
# PS: parametrize can be easily immitated, but still quicktests would be even more useful

# disableLogging()

proc gasMeters: seq[GasMeter] =
  @[newGasMeter(10), newGasMeter(100), newGasMeter(999)]

macro all(element: untyped, handler: untyped): untyped =
  let name = ident(&"{element.repr}s")
  result = quote:
    var res = `name`()
    for `element` in res.mitems:
      `handler`

# @pytest.mark.parametrize("value", (0, 10))
# def test_start_gas_on_instantiation(value):
#     meter = GasMeter(value)
#     assert meter.start_gas == value
#     assert meter.gas_remaining == value
#     assert meter.gas_refunded == 0


# @pytest.mark.parametrize("value", (-1, 2**256, 'a'))
# def test_instantiation_invalid_value(value):
#     with pytest.raises(ValidationError):
#         GasMeter(value)


# @pytest.mark.parametrize("amount", (0, 1, 10))
# def test_consume_gas(gas_meter, amount):
#     gas_meter.consume_gas(amount, "reason")
#     assert gas_meter.gas_remaining == gas_meter.start_gas - amount


# @pytest.mark.parametrize("amount", (0, 1, 99))
# def test_return_gas(gas_meter, amount):
#     gas_meter.return_gas(amount)
#     assert gas_meter.gas_remaining == (gas_meter.start_gas + amount)

# @pytest.mark.parametrize("amount", (0, 1, 99))
# def test_refund_gas(gas_meter, amount):
#     gas_meter.refund_gas(amount)
#     assert gas_meter.gas_refunded == amount


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
      check(gasMeter.gasRemaining == gasMeter.startGas)
      let consume = gasMeter.startGas
      gasMeter.consumeGas(consume, "0")
      check(gasMeter.gasRemaining - (gasMeter.startGas - consume) == 0)

  test "consume errors":
    all(gasMeter):
      check(gasMeter.gasRemaining == gasMeter.startGas)
      expect(OutOfGas):
        gasMeter.consumeGas(gasMeter.startGas + 1, "")

  test "return refund works correctly":
    all(gasMeter):
      check(gasMeter.gasRemaining == gasMeter.startGas)
      check(gasMeter.gasRefunded == 0)
      gasMeter.consumeGas(5, "")
      check(gasMeter.gasRemaining == gasMeter.startGas - 5)
      gasMeter.returnGas(5)
      check(gasMeter.gasRemaining == gasMeter.startGas)
      gasMeter.refundGas(5)
      check(gasMeter.gasRefunded == 5)
