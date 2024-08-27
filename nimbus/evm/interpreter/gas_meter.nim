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

func consumeGas*(
    gasMeter: var GasMeter; amount: GasInt; reason: static string): EvmResultVoid {.inline.} =
  # consumeGas is a hotspot in the vm due to it being called for every
  # instruction
  # TODO report reason - consumeGas is a hotspot in EVM execution so it has to
  #      be done carefully
  if amount > gasMeter.gasRemaining:
    return err(gasErr(OutOfGas))
  gasMeter.gasRemaining -= amount
  ok()

func returnGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.gasRemaining += amount

func refundGas*(gasMeter: var GasMeter; amount: int64) =
  # EIP-2183 Net gas metering for sstore is built upon idea
  # that the refund counter is only one in an EVM like geth does.
  # EIP-2183 gurantee that the counter can never go below zero.
  # But nimbus, EVMC, and emvone taken different route, the refund counter
  # is present at each level of recursion. That's why EVMC/evmone is using
  # int64 while geth using uint64 for their gas calculation.
  # After nimbus converting GasInt to uint64, the gas refund
  # cannot be converted to uint64 too, because the sum of all children gas refund,
  # no matter positive or negative will be >= 0 when EVM finish execution.
  gasMeter.gasRefunded += amount
