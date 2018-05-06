# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  ../logging, ../errors, ../constants, stint

type
  GasMeter* = ref object
    logger*: Logger
    gasRefunded*: UInt256
    startGas*: UInt256
    gasRemaining*: UInt256

proc newGasMeter*(startGas: UInt256): GasMeter =
  new(result)
  result.startGas = startGas
  result.gasRemaining = result.startGas
  result.gasRefunded = 0.u256
  result.logger = logging.getLogger("gas")

proc consumeGas*(gasMeter: var GasMeter; amount: UInt256; reason: string) =
  #if amount < 0.u256:
  #  raise newException(ValidationError, "Gas consumption amount must be positive")
  if amount > gasMeter.gasRemaining:
    raise newException(OutOfGas,
      &"Out of gas: Needed {amount} - Remaining {gasMeter.gasRemaining} - Reason: {reason}")
  gasMeter.gasRemaining -= amount
  gasMeter.logger.trace(
    &"GAS CONSUMPTION: {gasMeter.gasRemaining + amount} - {amount} -> {gasMeter.gasRemaining} ({reason})")

proc returnGas*(gasMeter: var GasMeter; amount: UInt256) =
  #if amount < 0.int256:
  #  raise newException(ValidationError, "Gas return amount must be positive")
  gasMeter.gasRemaining += amount
  gasMeter.logger.trace(
    &"GAS RETURNED: {gasMeter.gasRemaining - amount} + {amount} -> {gasMeter.gasRemaining}")

proc refundGas*(gasMeter: var GasMeter; amount: UInt256) =
  #if amount < 0.int256:
  #  raise newException(ValidationError, "Gas refund amount must be positive")
  gasMeter.gasRefunded += amount
  gasMeter.logger.trace(
    &"GAS REFUND: {gasMeter.gasRemaining - amount} + {amount} -> {gasMeter.gasRefunded}")
