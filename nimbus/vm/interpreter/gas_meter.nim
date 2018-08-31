# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, eth_common, # GasInt
  ../../errors, ../../vm_types

logScope:
  topics = "vm gas"

proc init*(m: var GasMeter, startGas: GasInt) =
  m.startGas = startGas
  m.gasRemaining = m.startGas
  m.gasRefunded = 0

proc consumeGas*(gasMeter: var GasMeter; amount: GasInt; reason: string) =
  #if amount < 0.u256:
  #  raise newException(ValidationError, "Gas consumption amount must be positive")
  # Alternatively: use a range type `range[0'i64 .. high(int64)]`
  #   https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  if amount > gasMeter.gasRemaining:
    raise newException(OutOfGas,
      &"Out of gas: Needed {amount} - Remaining {gasMeter.gasRemaining} - Reason: {reason}")
  gasMeter.gasRemaining -= amount

  when defined(nimbusTrace): # XXX: https://github.com/status-im/nim-chronicles/issues/26
    debug(
      "GAS CONSUMPTION", total = gasMeter.gasRemaining + amount, amount, remaining = gasMeter.gasRemaining, reason)

proc returnGas*(gasMeter: var GasMeter; amount: GasInt) =
  #if amount < 0.int256:
  #  raise newException(ValidationError, "Gas return amount must be positive")
  # Alternatively: use a range type `range[0'i64 .. high(int64)]`
  #   https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  gasMeter.gasRemaining += amount
  when defined(nimbusTrace): # XXX: https://github.com/status-im/nim-chronicles/issues/26
    debug(
      "GAS RETURNED", consumed = gasMeter.gasRemaining - amount, amount, remaining = gasMeter.gasRemaining)

proc refundGas*(gasMeter: var GasMeter; amount: GasInt) =
  #if amount < 0.int256:
  #  raise newException(ValidationError, "Gas refund amount must be positive")
  # Alternatively: use a range type `range[0'i64 .. high(int64)]`
  #   https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  gasMeter.gasRefunded += amount
  when defined(nimbusTrace): # XXX: https://github.com/status-im/nim-chronicles/issues/26
    debug(
      "GAS REFUND", consumed = gasMeter.gasRemaining - amount, amount, refunded = gasMeter.gasRefunded)
