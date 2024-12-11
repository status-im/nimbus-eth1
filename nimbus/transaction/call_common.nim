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
  ../evm/[message, precompiles, internals, interpreter_dispatch],
  ../db/ledger,
  ../common/evmforks,
  ../core/eip4844,
  ../core/eip7702,
  ./host_types,
  ./call_types

import ../evm/computation except fromEvmc, toEvmc

when defined(evmc_enabled):
  import
    ../utils/utils,
    ./host_services

export
  call_types

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
      # If the `call.to` has a delegation, also warm its target.
      let target = parseDelegationAddress(db.getCode(call.to))
      if target.isSome:
        db.accessList(target[])

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

proc preExecComputation(vmState: BaseVMState, call: CallParams): int64 =
  var gasRefund = 0
  let ledger = vmState.stateDB

  if not call.isCreate:
    ledger.incNonce(call.sender)

  # EIP-7702
  for auth in call.authorizationList:
    # 1. Verify the chain id is either 0 or the chain's current ID.
    if not(auth.chainId == 0.ChainId or auth.chainId == vmState.com.chainId):
      continue

    # 2. authority = ecrecover(keccak(MAGIC || rlp([chain_id, address, nonce])), y_parity, r, s]
    let authority = authority(auth).valueOr:
      continue

    # 3. Add authority to accessed_addresses (as defined in EIP-2929.)
    ledger.accessList(authority)

    # 4. Verify the code of authority is either empty or already delegated.
    let code = ledger.getCode(authority)
    if code.len > 0:
      if not parseDelegation(code):
        continue

    # 5. Verify the nonce of authority is equal to nonce.
    if ledger.getNonce(authority) != auth.nonce:
      continue

    # 6. Add PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST gas to the global refund counter if authority exists in the trie.
    if ledger.accountExists(authority):
      gasRefund += PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST

    # 7. Set the code of authority to be 0xef0100 || address. This is a delegation designation.
    if auth.address == default(eth_types.Address):
      ledger.setCode(authority, @[])
    else:
      ledger.setCode(authority, @(addressToDelegation(auth.address)))

    # 8. Increase the nonce of authority by one.
    ledger.setNonce(authority, auth.nonce + 1)

    # Usually the transaction destination and delegation target are added to
    # the access list in initialAccessListEIP2929, however if the delegation is in
    # the same transaction we need add here as to reduce calling slow ecrecover.
    if call.to == authority:
      ledger.accessList(auth.address)

  gasRefund

proc setupHost(call: CallParams, keepStack: bool): TransactionHost =  
  let vmState = call.vmState
  vmState.txCtx = TxContext(
    origin         : call.origin.get(call.sender),
    gasPrice       : call.gasPrice,
    versionedHashes: call.versionedHashes,
    blobBaseFee    : getBlobBaseFee(vmState.blockCtx.excessBlobGas),
  )

  # reset global gasRefund counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0
  
  let
    intrinsicGas = if call.noIntrinsic: 0.GasInt
                   else: intrinsicGas(call, vmState.fork)
    host = TransactionHost(
      vmState: vmState,
      sysCall: call.sysCall,
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
    gasRefund = if call.sysCall: 0
                else: preExecComputation(vmState, call)
    code = if call.isCreate:
             let contractAddress = generateContractAddress(call.vmState, EVMC_CREATE, call.sender)
             host.msg.recipient = contractAddress.toEvmc
             host.msg.input_size = 0
             host.msg.input_data = nil
             CodeBytesRef.init(call.input)
           else:          
             if call.input.len > 0:
               host.msg.input_size = call.input.len.csize_t
               # Must copy the data so the `host.msg.input_data` pointer
               # remains valid after the end of `call` lifetime.
               host.input = call.input
               host.msg.input_data = host.input[0].addr
             getCallCode(host.vmState, host.msg.code_address.fromEvmc)
    cMsg = hostToComputationMessage(host.msg)
    
  host.computation = newComputation(vmState, keepStack, cMsg, code)
  host.code = code

  host.computation.addRefund(gasRefund)
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
  else:
    if c.shouldBurnGas:
      c.gasMeter.gasRemaining = 0
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

  when T is CallResult|DebugCallResult:
    # Collecting the result can be unnecessarily expensive when (re)-processing
    # transactions
    if c.isError:
      result.error = c.error.info
    result.gasUsed = call.gasLimit - gasRemaining
    result.output = system.move(c.output)
    result.contractAddress = if call.isCreate: c.msg.contractAddress
                            else: default(HostAddress)

    when T is DebugCallResult:
      result.stack = move(c.finalStack)
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
  let host = setupHost(call, keepStack = T is DebugCallResult)
  prepareToRunComputation(host, call)

  when defined(evmc_enabled):
    doExecEvmc(host, call)
  else:
    host.computation.execCallOrCreate()
    if not call.sysCall:
      host.computation.postExecComputation()

  finishRunningComputation(host, call, T)
