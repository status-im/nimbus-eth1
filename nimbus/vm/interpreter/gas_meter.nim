# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, eth_common, # GasInt
  ../../logging, ../../errors, ../../vm_types

proc newGasMeter*(startGas: GasInt): GasMeter =
  new(result)
  result.startGas = startGas
  result.gasRemaining = result.startGas
  result.gasRefunded = 0
  result.logger = logging.getLogger("gas")

proc consumeGas*(gasMeter: var GasMeter; amount: GasInt; reason: string) =
  #if amount < 0.u256:
  #  raise newException(ValidationError, "Gas consumption amount must be positive")
  # Alternatively: use a range type `range[0'i64 .. high(int64)]`
  #   https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  if amount > gasMeter.gasRemaining:
    raise newException(OutOfGas,
      &"Out of gas: Needed {amount} - Remaining {gasMeter.gasRemaining} - Reason: {reason}")
  gasMeter.gasRemaining -= amount
  gasMeter.logger.trace(
    &"GAS CONSUMPTION: {gasMeter.gasRemaining + amount} - {amount} -> {gasMeter.gasRemaining} ({reason})")

proc returnGas*(gasMeter: var GasMeter; amount: GasInt) =
  #if amount < 0.int256:
  #  raise newException(ValidationError, "Gas return amount must be positive")
  # Alternatively: use a range type `range[0'i64 .. high(int64)]`
  #   https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  gasMeter.gasRemaining += amount
  gasMeter.logger.trace(
    &"GAS RETURNED: {gasMeter.gasRemaining - amount} + {amount} -> {gasMeter.gasRemaining}")

proc refundGas*(gasMeter: var GasMeter; amount: GasInt) =
  #if amount < 0.int256:
  #  raise newException(ValidationError, "Gas refund amount must be positive")
  # Alternatively: use a range type `range[0'i64 .. high(int64)]`
  #   https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  gasMeter.gasRefunded += amount
  gasMeter.logger.trace(
    &"GAS REFUND: {gasMeter.gasRemaining - amount} + {amount} -> {gasMeter.gasRefunded}")
