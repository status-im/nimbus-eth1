# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common, # GasInt
  ../evm_errors,
  ../types

func init*(m: var GasMeter, startGas: GasInt) =
  m.gasRemaining = startGas
  m.gasRefunded = 0

func consumeGas*(gasMeter: var GasMeter; amount: GasInt; reason: string): EvmResultVoid =
  if amount > gasMeter.gasRemaining:
    return err(memErr(OutOfGas))
  gasMeter.gasRemaining -= amount
  ok()

func returnGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.gasRemaining += amount

# some gasRefunded operations still relying
# on negative number
func refundGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.gasRefunded += amount
