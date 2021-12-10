# Nimbus - Common entry point to the EVM from all different callers
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/common/eth_types, stint, options, stew/ranges/ptr_arith,
  ".."/[vm_types, vm_state, vm_computation, vm_state_transactions],
  ".."/[vm_internals, vm_precompiles, vm_gas_costs],
  ".."/[db/accounts_cache, forks],
  ./host_types

when defined(evmc_enabled):
  import ".."/[utils]
  import ./host_services

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
    accessList*:   AccessList           # EIP-2930 (Berlin) tx access list.
    noIntrinsic*:  bool                 # Don't charge intrinsic gas.
    noAccessList*: bool                 # Don't initialise EIP-2929 access list.
    noGasCharge*:  bool                 # Don't charge sender account for gas.
    noRefund*:     bool                 # Don't apply gas refund/burn rule.

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

proc hostToComputationMessage*(msg: EvmcMessage): Message =
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

func intrinsicGas*(call: CallParams, fork: Fork): GasInt {.inline.} =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation).
  var gas = gasFees[fork][GasTransaction]

  # EIP-2 (Homestead) extra intrinsic gas for contract creations.
  if call.isCreate:
    gas += gasFees[fork][GasTXCreate]

  # Input data cost, reduced in EIP-2028 (Istanbul).
  let gasZero    = gasFees[fork][GasTXDataZero]
  let gasNonZero = gasFees[fork][GasTXDataNonZero]
  for b in call.input:
    gas += (if b == 0: gasZero else: gasNonZero)

  # EIP-2930 (Berlin) intrinsic gas for transaction access list.
  if fork >= FkBerlin:
    for account in call.accessList:
      gas += ACCESS_LIST_ADDRESS_COST
      gas += account.storageKeys.len * ACCESS_LIST_STORAGE_KEY_COST
  return gas

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

    # EIP2930 optional access list.
    for account in call.accessList:
      db.accessList(account.address)
      for key in account.storageKeys:
        db.accessList(account.address, UInt256.fromBytesBE(key))

proc setupHost(call: CallParams): TransactionHost =
  let vmState = call.vmState
  vmState.setupTxContext(
    origin       = call.origin.get(call.sender),
    gasPrice     = call.gasPrice,
    forkOverride = call.forkOverride
  )

  var intrinsicGas: GasInt = 0
  if not call.noIntrinsic:
    intrinsicGas = intrinsicGas(call, vmState.fork)

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

  # Generate new contract address, prepare code, and update message `destination`
  # with the contract address.  This differs from the previous Nimbus EVM API.
  # Guarded under `evmc_enabled` for now so it doesn't break vm2.
  when defined(evmc_enabled):
    var code: seq[byte]
    if call.isCreate:
      let sender = call.sender
      let contractAddress =
        generateAddress(sender, call.vmState.readOnlyStateDB.getNonce(sender))
      host.msg.destination = contractAddress.toEvmc
      host.msg.input_size = 0
      host.msg.input_data = nil
      code = call.input
    else:
      # TODO: Share the underlying data, but only after checking this does not
      # cause problems with the database.
      code = host.vmState.readOnlyStateDB.getCode(host.msg.destination.fromEvmc)
      if call.input.len > 0:
        host.msg.input_size = call.input.len.csize_t
        # Must copy the data so the `host.msg.input_data` pointer
        # remains valid after the end of `call` lifetime.
        host.input = call.input
        host.msg.input_data = host.input[0].addr

    let cMsg = hostToComputationMessage(host.msg)
    host.computation = newComputation(vmState, cMsg, code)
    shallowCopy(host.code, code)

  else:
    if call.input.len > 0:
      host.msg.input_size = call.input.len.csize_t
      # Must copy the data so the `host.msg.input_data` pointer
      # remains valid after the end of `call` lifetime.
      host.input = call.input
      host.msg.input_data = host.input[0].addr

    let cMsg = hostToComputationMessage(host.msg)
    host.computation = newComputation(vmState, cMsg)

  return host

when defined(evmc_enabled):
  import ./host_services
  proc doExecEvmc(host: TransactionHost, call: CallParams) =
    var callResult = evmcExecComputation(host)
    let c = host.computation

    if callResult.status_code == EVMC_SUCCESS:
      c.error = nil
    elif callResult.status_code == EVMC_REVERT:
      c.setError("EVMC_REVERT", false)
    else:
      c.setError($callResult.status_code, true)

    c.gasMeter.gasRemaining = callResult.gas_left
    c.msg.contractAddress = callResult.create_address.fromEvmc
    c.output = if callResult.output_size <= 0: @[]
               else: @(makeOpenArray(callResult.output_data,
                                     callResult.output_size.int))
    if not callResult.release.isNil:
      {.gcsafe.}:
        callResult.release(callResult)

proc runComputation*(call: CallParams): CallResult =
  let host = setupHost(call)
  let c = host.computation

  # Must come after `setupHost` for correct fork.
  if not call.noAccessList:
    initialAccessListEIP2929(call)

  # Charge for gas.
  if not call.noGasCharge:
    host.vmState.mutateStateDB:
      db.subBalance(call.sender, call.gasLimit.u256 * call.gasPrice.u256)

  when defined(evmc_enabled):
    doExecEvmc(host, call)
  else:
    execComputation(host.computation)

  # EIP-3529: Reduction in refunds
  let MaxRefundQuotient = if host.vmState.fork >= FkLondon:
                            5.GasInt
                          else:
                            2.GasInt

  # Calculated gas used, taking into account refund rules.
  var gasRemaining: GasInt = 0
  if call.noRefund:
    gasRemaining = c.gasMeter.gasRemaining
  elif not c.shouldBurnGas:
    let maxRefund = (call.gasLimit - c.gasMeter.gasRemaining) div MaxRefundQuotient
    let refund = min(c.getGasRefund(), maxRefund)
    c.gasMeter.returnGas(refund)
    gasRemaining = c.gasMeter.gasRemaining

  # Refund for unused gas.
  if gasRemaining > 0 and not call.noGasCharge:
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
