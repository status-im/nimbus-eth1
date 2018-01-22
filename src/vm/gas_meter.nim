import
  strformat,
  ../logging, ../errors, ../constants, bigints

type
  GasMeter* = ref object
    logger*: Logger
    gasRefunded*: Int256
    startGas*: Int256
    gasRemaining*: Int256

proc newGasMeter*(startGas: Int256): GasMeter =
  new(result)
  result.startGas = startGas
  result.gasRemaining = result.startGas
  result.gasRefunded = 0.int256

proc consumeGas*(gasMeter: var GasMeter; amount: Int256; reason: string) =
  if amount < 0.int256:
    raise newException(ValidationError, "Gas consumption amount must be positive")
  if amount > gasMeter.gasRemaining:
    raise newException(OutOfGas,
      &"Out of gas: Needed {amount} - Remaining {gasMeter.gasRemaining} - Reason: {reason}")
  gasMeter.gasRemaining -= amount
  gasMeter.logger.trace(
    &"GAS CONSUMPTION: {gasMeter.gasRemaining + amount} - {amount} -> {gasMeter.gasRemaining} ({reason})")

proc returnGas*(gasMeter: var GasMeter; amount: Int256) =
  if amount < 0.int256:
    raise newException(ValidationError, "Gas return amount must be positive")
  gasMeter.gasRemaining += amount
  gasMeter.logger.trace(
    &"GAS RETURNED: {gasMeter.gasRemaining - amount} + {amount} -> {gasMeter.gasRemaining}")

proc refundGas*(gasMeter: var GasMeter; amount: Int256) =
  if amount < 0.int256:
    raise newException(ValidationError, "Gas refund amount must be positive")
  gasMeter.gasRefunded += amount
  gasMeter.logger.trace(
    &"GAS REFUND: {gasMeter.gasRemaining - amount} + {amount} -> {gasMeter.gasRefunded}")
