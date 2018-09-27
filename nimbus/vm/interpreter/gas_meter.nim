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
  if amount > gasMeter.gasRemaining:
    raise newException(OutOfGas,
      &"Out of gas: Needed {amount} - Remaining {gasMeter.gasRemaining} - Reason: {reason}")
  gasMeter.gasRemaining -= amount

  when defined(nimbusTrace): # XXX: https://github.com/status-im/nim-chronicles/issues/26
    debug(
      "GAS CONSUMPTION", total = gasMeter.gasRemaining + amount, amount, remaining = gasMeter.gasRemaining, reason)

proc returnGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.gasRemaining += amount
  when defined(nimbusTrace): # XXX: https://github.com/status-im/nim-chronicles/issues/26
    debug(
      "GAS RETURNED", consumed = gasMeter.gasRemaining - amount, amount, remaining = gasMeter.gasRemaining)

proc refundGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.gasRefunded += amount
  when defined(nimbusTrace): # XXX: https://github.com/status-im/nim-chronicles/issues/26
    debug(
      "GAS REFUND", consumed = gasMeter.gasRemaining - amount, amount, refunded = gasMeter.gasRefunded)
