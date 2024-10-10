# Nimbus - Common entry point to the EVM from all different callers
#
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/eth_types, stint, stew/ptrops,
  chronos,
  results,
  stew/saturation_arith,
  ../evm/[types, state],
  ../evm/[precompiles, internals],
  ../db/ledger,
  ../common/evmforks,
  ../core/eip4844,
  ./host_types

import ../evm/computation except fromEvmc, toEvmc

when defined(evmc_enabled):
  import
    ../utils/utils,
    ./host_services
else:
  import
    ../evm/state_transactions

type
  # Standard call parameters.
  CallParams* = object
    vmState*:      BaseVMState          # Chain, database, state, block, fork.
    origin*:       Opt[HostAddress]     # Default origin is `sender`.
    gasPrice*:     GasInt               # Gas price for this call.
    gasLimit*:     GasInt               # Maximum gas available for this call.
    sender*:       HostAddress          # Sender account.
    to*:           HostAddress          # Recipient (ignored when `isCreate`).
    isCreate*:     bool                 # True if this is a contract creation.
    value*:        HostValue            # Value sent from sender to recipient.
    input*:        seq[byte]            # Input data.
    accessList*:   AccessList           # EIP-2930 (Berlin) tx access list.
    versionedHashes*: seq[VersionedHash]   # EIP-4844 (Cancun) blob versioned hashes
    noIntrinsic*:  bool                 # Don't charge intrinsic gas.
    noAccessList*: bool                 # Don't initialise EIP-2929 access list.
    noGasCharge*:  bool                 # Don't charge sender account for gas.
    noRefund*:     bool                 # Don't apply gas refund/burn rule.
    sysCall*:      bool                 # System call or ordinary call

  # Standard call result.  (Some fields are beyond what EVMC can return,
  # and must only be used from tests because they will not always be set).
  CallResult* = object
    error*:           string            # Something if the call failed.
    gasUsed*:         GasInt            # Gas used by the call.
    contractAddress*: EthAddress        # Created account (when `isCreate`).
    output*:          seq[byte]         # Output data.
    stack*:           EvmStack       # EVM stack on return (for test only).
    memory*:          EvmMemory      # EVM memory on return (for test only).

func isError*(cr: CallResult): bool =
  cr.error.len > 0

proc hostToComputationMessage*(msg: EvmcMessage): Message =
  Message(
    kind:            CallKind(msg.kind.ord),
    depth:           msg.depth,
    gas:             GasInt msg.gas,
    sender:          msg.sender.fromEvmc,
    contractAddress: msg.recipient.fromEvmc,
    codeAddress:     msg.code_address.fromEvmc,
    value:           msg.value.fromEvmc,
    # When input size is zero, input data pointer may be null.
    data:            if msg.input_size <= 0: @[]
                     else: @(makeOpenArray(msg.input_data, msg.input_size.int)),
    flags:           msg.flags
  )

func intrinsicGas*(call: CallParams, vmState: BaseVMState): GasInt {.inline.} =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation).
  let fork = vmState.fork
  var gas = gasFees[fork][GasTransaction]

  # EIP-2 (Homestead) extra intrinsic gas for contract creations.
  if call.isCreate:
    gas += gasFees[fork][GasTXCreate]
    if fork >= FkShanghai:
      gas += (gasFees[fork][GasInitcodeWord] * call.input.len.wordCount)

  # Input data cost, reduced in EIP-2028 (Istanbul).
  let gasZero    = gasFees[fork][GasTXDataZero]
  let gasNonZero = gasFees[fork][GasTXDataNonZero]
  for b in call.input:
    gas += (if b == 0: gasZero else: gasNonZero)

  # EIP-2930 (Berlin) intrinsic gas for transaction access list.
  if fork >= FkBerlin:
    for account in call.accessList:
      gas += ACCESS_LIST_ADDRESS_COST
      gas += GasInt(account.storageKeys.len) * ACCESS_LIST_STORAGE_KEY_COST

  return gas.GasInt

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

    # EIP3651 adds coinbase to the list of addresses that should start warm.
    if vmState.fork >= FkShanghai:
      db.accessList(vmState.coinbase)

    # Adds the correct subset of precompiles.
    for c in activePrecompiles(vmState.fork):
      db.accessList(c)

    # EIP2930 optional access list.
    for account in call.accessList:
      db.accessList(account.address)
      for key in account.storageKeys:
        db.accessList(account.address, key.to(UInt256))

proc setupHost(call: CallParams): TransactionHost =
  let vmState = call.vmState
  vmState.txCtx = TxContext(
    origin         : call.origin.get(call.sender),
    gasPrice       : call.gasPrice,
    versionedHashes: call.versionedHashes,
    blobBaseFee    : getBlobBaseFee(vmState.blockCtx.excessBlobGas),
  )

  var intrinsicGas: GasInt = 0
  if not call.noIntrinsic:
    intrinsicGas = intrinsicGas(call, vmState)

  let host = TransactionHost(
    vmState:       vmState,
    msg: EvmcMessage(
      kind:         if call.isCreate: EVMC_CREATE else: EVMC_CALL,
      # Default: flags:       {},
      # Default: depth:       0,
      gas:          int64.saturate(call.gasLimit - intrinsicGas),
      recipient:    call.to.toEvmc,
      code_address: call.to.toEvmc,
      sender:       call.sender.toEvmc,
      value:        call.value.toEvmc,
    )
    # All other defaults in `TransactionHost` are fine.
  )

  # Generate new contract address, prepare code, and update message `recipient`
  # with the contract address.  This differs from the previous Nimbus EVM API.
  # Guarded under `evmc_enabled` for now so it doesn't break vm2.
  when defined(evmc_enabled):
    var code: CodeBytesRef
    if call.isCreate:
      let sender = call.sender
      let contractAddress =
        generateAddress(sender, call.vmState.readOnlyStateDB.getNonce(sender))
      host.msg.recipient = contractAddress.toEvmc
      host.msg.input_size = 0
      host.msg.input_data = nil
      code = CodeBytesRef.init(call.input)
    else:
      # TODO: Share the underlying data, but only after checking this does not
      # cause problems with the database.
      code = host.vmState.readOnlyStateDB.getCode(host.msg.code_address.fromEvmc)
      if call.input.len > 0:
        host.msg.input_size = call.input.len.csize_t
        # Must copy the data so the `host.msg.input_data` pointer
        # remains valid after the end of `call` lifetime.
        host.input = call.input
        host.msg.input_data = host.input[0].addr

    let cMsg = hostToComputationMessage(host.msg)
    host.computation = newComputation(vmState, call.sysCall, cMsg, code)

    host.code = code

  else:
    if call.input.len > 0:
      host.msg.input_size = call.input.len.csize_t
      # Must copy the data so the `host.msg.input_data` pointer
      # remains valid after the end of `call` lifetime.
      host.input = call.input
      host.msg.input_data = host.input[0].addr

    let cMsg = hostToComputationMessage(host.msg)
    host.computation = newComputation(vmState, call.sysCall, cMsg)

  vmState.captureStart(host.computation, call.sender, call.to,
                       call.isCreate, call.input,
                       call.gasLimit, call.value)

  return host

when defined(evmc_enabled):
  proc doExecEvmc(host: TransactionHost, call: CallParams) =
    var callResult = evmcExecComputation(host)
    let c = host.computation

    if callResult.status_code == EVMC_SUCCESS:
      c.error = nil
    elif callResult.status_code == EVMC_REVERT:
      c.setError(EVMC_REVERT, false)
    else:
      c.setError(callResult.status_code, true)

    c.gasMeter.gasRemaining = GasInt callResult.gas_left
    c.msg.contractAddress = callResult.create_address.fromEvmc
    c.output = if callResult.output_size <= 0: @[]
               else: @(makeOpenArray(callResult.output_data,
                                     callResult.output_size.int))
    if not callResult.release.isNil:
      {.gcsafe.}:
        callResult.release(callResult)

# FIXME-awkwardFactoring: the factoring out of the pre and
# post parts feels awkward to me, but for now I'd really like
# not to have too much duplicated code between sync and async.
# --Adam

proc prepareToRunComputation(host: TransactionHost, call: CallParams) =
  # Must come after `setupHost` for correct fork.
  if not call.noAccessList:
    initialAccessListEIP2929(call)

  # Charge for gas.
  if not call.noGasCharge:
    let
      vmState = host.vmState
      fork = vmState.fork

    vmState.mutateStateDB:
      db.subBalance(call.sender, call.gasLimit.u256 * call.gasPrice.u256)

      # EIP-4844
      if fork >= FkCancun:
        let blobFee = calcDataFee(call.versionedHashes.len,
          vmState.blockCtx.excessBlobGas)
        db.subBalance(call.sender, blobFee)

proc calculateAndPossiblyRefundGas(host: TransactionHost, call: CallParams): GasInt =
  let c = host.computation

  # EIP-3529: Reduction in refunds
  let MaxRefundQuotient = if host.vmState.fork >= FkLondon:
                            5.GasInt
                          else:
                            2.GasInt

  # Calculated gas used, taking into account refund rules.
  if call.noRefund:
    result = c.gasMeter.gasRemaining
  elif not c.shouldBurnGas:
    let maxRefund = (call.gasLimit - c.gasMeter.gasRemaining) div MaxRefundQuotient
    let refund = min(c.getGasRefund(), maxRefund)
    c.gasMeter.returnGas(refund)
    result = c.gasMeter.gasRemaining

  # Refund for unused gas.
  if result > 0 and not call.noGasCharge:
    host.vmState.mutateStateDB:
      db.addBalance(call.sender, result.u256 * call.gasPrice.u256)

proc finishRunningComputation(
    host: TransactionHost, call: CallParams, T: type): T =
  let c = host.computation

  let gasRemaining = calculateAndPossiblyRefundGas(host, call)
  # evm gas used without intrinsic gas
  let gasUsed = host.msg.gas.GasInt - gasRemaining
  host.vmState.captureEnd(c, c.output, gasUsed, c.errorOpt)

  when T is CallResult:
    # Collecting the result can be unnecessarily expensive when (re)-processing
    # transactions
    if c.isError:
      result.error = c.error.info
    result.gasUsed = call.gasLimit - gasRemaining
    result.output = system.move(c.output)
    result.contractAddress = if call.isCreate: c.msg.contractAddress
                            else: default(HostAddress)
    result.stack = move(c.stack)
    result.memory = move(c.memory)
  elif T is GasInt:
    result = call.gasLimit - gasRemaining
  elif T is string:
    if c.isError:
      result = c.error.info
  elif T is seq[byte]:
    result = move(c.output)
  else:
    {.error: "Unknown computation output".}

proc runComputation*(call: CallParams, T: type): T =
  let host = setupHost(call)
  prepareToRunComputation(host, call)

  when defined(evmc_enabled):
    doExecEvmc(host, call)
  else:
    if host.computation.sysCall:
      execSysCall(host.computation)
    else:
      execComputation(host.computation)

  finishRunningComputation(host, call, T)
