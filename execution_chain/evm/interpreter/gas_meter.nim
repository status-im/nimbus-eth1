# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  eth/common/base,
  ../evm_errors,
  ../types

func init*(m: var GasMeter, startGas: GasInt, stateGas: GasInt) =
  m.gasRemaining = startGas
  m.gasRefunded = 0
  m.stateGasLeft = stateGas
  m.stateGasUsed = 0
  m.regularGasUsed = 0

template consumeGas*(
    gasMeter: var GasMeter; amount: GasInt; reason: static string): EvmResultVoid =
  # consumeGas is a hotspot in the vm due to it being called for every
  # instruction
  # TODO report reason - consumeGas is a hotspot in EVM execution so it has to
  #      be done carefully
  if amount > gasMeter.gasRemaining:
    EvmResultVoid.err(gasErr(OutOfGas))
  else:
    gasMeter.regularGasUsed += amount
    gasMeter.gasRemaining -= amount
    EvmResultVoid.ok()

func returnGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.gasRemaining += amount

func refundGas*(gasMeter: var GasMeter; amount: int64) =
  # EIP-2183 Net gas metering for sstore is built upon idea
  # that the refund counter is only one in an EVM like geth does.
  # EIP-2183 guarantee that the counter can never go below zero.
  # But nimbus, EVMC, and emvone taken different route, the refund counter
  # is present at each level of recursion. That's why EVMC/evmone is using
  # int64 while geth using uint64 for their gas calculation.
  # After nimbus converting GasInt to uint64, the gas refund
  # cannot be converted to uint64 too, because the sum of all children gas refund,
  # no matter positive or negative will be >= 0 when EVM finish execution.
  gasMeter.gasRefunded += amount

func chargeStateGas*(gasMeter: var GasMeter; amount: GasInt, reason: string): EvmResultVoid =
  if gasMeter.stateGasLeft >= amount:
    gasMeter.stateGasLeft -= amount
  elif gasMeter.stateGasLeft + gasMeter.gasRemaining >= amount:
    let remainder = amount - gasMeter.stateGasLeft
    gasMeter.stateGasLeft = 0
    gasMeter.gasRemaining -= remainder
  else:
    return EvmResultVoid.err(gasErr(OutOfGas))

  gasMeter.stateGasUsed += amount
  EvmResultVoid.ok()

func returnStateGas*(gasMeter: var GasMeter; amount: GasInt) =
  gasMeter.stateGasLeft += amount

func burnGas*(gasMeter: var GasMeter) =
  gasMeter.regularGasUsed += gasMeter.gasRemaining
  gasMeter.gasRemaining = 0

func escrowSubcallRegularGas*(gasMeter: var GasMeter, subCallGas: GasInt) =
  # Remove forwarded CALL* gas from the caller's regular gas usage.
  #
  # CALL* forwards `subCallGas` to the child frame as temporary escrow.
  # Only gas actually burned by the child should be reintroduced via
  # `incorporate_child_*` child gas accounting.

  gasMeter.regularGasUsed -= subCallGas

func appendRegularGasUsed*(gasMeter: var GasMeter, amount: GasInt) =
  gasMeter.regularGasUsed += amount

func appendStateGasUsed*(gasMeter: var GasMeter, amount: GasInt) =
  gasMeter.stateGasUsed += amount

func checkGas*(gasMeter: GasMeter, cost, amount: GasInt): EvmResultVoid =
  # Check enough state gas after `cost` consumption.
  if amount > gasMeter.stateGasLeft + gasMeter.gasRemaining - cost:
    return err(gasErr(OutOfGas))
  ok()

func returnAllStateGas*(gasMeter: var GasMeter) =
  gasMeter.stateGasLeft += gasMeter.stateGasUsed
  gasMeter.stateGasUsed = 0
