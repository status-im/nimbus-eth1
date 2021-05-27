# Nimbus - Common entry point to the EVM from all different callers
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/common/eth_types, stint, options, stew/ranges/ptr_arith,
  ".."/[vm_types, vm_types2, vm_state, vm_computation, vm_state_transactions],
  ".."/[db/accounts_cache, transaction, vm_precompiles, vm_gas_costs],
  ".."/vm_internals,
  ./host_types

type
  # Standard call parameters.
  CallParams* = object
    vmState*:      BaseVMState          # Chain, database, state, block, fork.
    forkOverride*: Option[Fork]         # Default fork is usually correct.
    origin*:       Option[HostAddress]  # Default origin is `sender`.
    gasPrice*:     GasInt               # Gas price for this call.
    gasLimit*:     GasInt               # Maximum gas available for this call.
    sender*:       HostAddress          # Sender account.
    to*:           HostAddress          # Recipient (ignored when `isCreate`).
    isCreate*:     bool                 # True if this is a contract creation.
    value*:        HostValue            # Value sent from sender to recipient.
    input*:        seq[byte]            # Input data.

  # Standard call result.  (Some fields are beyond what EVMC can return,
  # and must only be used from tests because they will not always be set).
  CallResult* = object
    isError*:         bool              # True if the call failed.
    gasUsed*:         GasInt            # Gas used by the call.
    contractAddress*: EthAddress        # Created account (when `isCreate`).
    output*:          seq[byte]         # Output data.
    logEntries*:      seq[Log]          # Output logs.
    stack*:           Stack             # EVM stack on return (for test only).
    memory*:          Memory            # EVM memory on return (for test only).
    error*:           Error             # Error if `isError` (for test only).

proc hostToComputationMessage(msg: EvmcMessage): Message =
  Message(
    kind:            CallKind(msg.kind),
    depth:           msg.depth,
    gas:             msg.gas,
    sender:          msg.sender.fromEvmc,
    contractAddress: msg.destination.fromEvmc,
    codeAddress:     msg.destination.fromEvmc,
    value:           msg.value.fromEvmc,
    # When input size is zero, input data pointer may be null.
    data:            if msg.input_size <= 0: @[]
                     else: @(makeOpenArray(msg.input_data, msg.input_size.int)),
    flags:           if msg.isStatic: emvcStatic else: emvcNoFlags
  )

proc initialAccessListEIP2929(call: CallParams) =
  # EIP2929 initial access list.
  let vmState = call.vmState
  if vmState.fork < FkBerlin:
    return

  vmState.mutateStateDB:
    db.accessList(call.sender)
    # For contract creations the EVM will add the contract address to the
    # access list itself, after calculating the new contract address.
    if not call.isCreate:
      db.accessList(call.to)
    # TODO: Check this only adds the correct subset of precompiles.
    for c in activePrecompiles():
      db.accessList(c)

proc setupCall(call: CallParams, useIntrinsic: bool): TransactionHost =
  let vmState = call.vmState
  vmState.setupTxContext(
    origin       = call.origin.get(call.sender),
    gasPrice     = call.gasPrice,
    forkOverride = call.forkOverride
  )

  var intrinsicGas: GasInt = 0
  if useIntrinsic:
    intrinsicGas = intrinsicGas(call.input, vmState.fork)
    if call.isCreate:
      intrinsicGas += gasFees[vmState.fork][GasTXCreate]

  let host = TransactionHost(
    vmState:       vmState,
    msg: EvmcMessage(
      kind:        if call.isCreate: EVMC_CREATE else: EVMC_CALL,
      # Default: flags:       {},
      # Default: depth:       0,
      gas:         call.gasLimit - intrinsicGas,
      destination: call.to.toEvmc,
      sender:      call.sender.toEvmc,
      value:       call.value.toEvmc,
    )
    # All other defaults in `TransactionHost` are fine.
  )

  if call.input.len > 0:
    host.msg.input_size = call.input.len.csize_t
    # Must copy the data so the `host.msg.input_data` pointer
    # remains valid after the end of `call` lifetime.
    host.input = call.input
    host.msg.input_data = host.input[0].addr

  let cMsg = hostToComputationMessage(host.msg)
  host.computation = newComputation(vmState, cMsg)
  return host

proc setupComputation*(call: CallParams): Computation =
  return setupCall(call, false).computation

proc runComputation*(call: CallParams): CallResult =
  let host = setupCall(call, true)
  let c = host.computation

  # Must come after `setupCall` for correct fork.
  initialAccessListEIP2929(call)

  # Charge for gas.
  host.vmState.mutateStateDB:
    db.subBalance(call.sender, call.gasLimit.u256 * call.gasPrice.u256)

  execComputation(c)

  # Calculated gas used, taking into account refund rules.
  var gasRemaining: GasInt = 0
  if not c.shouldBurnGas:
    let maxRefund = (call.gasLimit - c.gasMeter.gasRemaining) div 2
    let refund = min(c.getGasRefund(), maxRefund)
    c.gasMeter.returnGas(refund)
    gasRemaining = c.gasMeter.gasRemaining

  # Refund for unused gas.
  if gasRemaining > 0:
    host.vmState.mutateStateDB:
      db.addBalance(call.sender, gasRemaining.u256 * call.gasPrice.u256)

  result.isError = c.isError
  result.gasUsed = call.gasLimit - gasRemaining
  shallowCopy(result.output, c.output)
  result.contractAddress = if call.isCreate: c.msg.contractAddress
                           else: default(HostAddress)
  shallowCopy(result.logEntries, c.logEntries)
  result.stack = c.stack
  result.memory = c.memory
  result.error = c.error
