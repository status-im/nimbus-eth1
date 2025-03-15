# Nimbus - Common entry point to the EVM from all different callers
#
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/eth_types, stint, stew/ptrops,
  chronos,
  results,
  ../evm/[types, state],
  ../evm/[message, precompiles, internals, interpreter_dispatch],
  ../db/ledger,
  ../common/evmforks,
  ../core/eip4844,
  ../core/eip7702,
  ./call_types

import ../evm/computation

export
  call_types

type
  TransactionHost = ref object
    vmState:         BaseVMState
    computation:     Computation
    sysCall:         bool
    floorDataGas:    GasInt

proc initialAccessListEIP2929(call: CallParams) =
  # EIP2929 initial access list.
  let vmState = call.vmState
  if vmState.fork < FkBerlin:
    return

  vmState.mutateLedger:
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
  let ledger = vmState.ledger

  if not call.isCreate:
    ledger.incNonce(call.sender)

  # EIP-7702
  for auth in call.authorizationList:
    # 1. Verify the chain id is either 0 or the chain's current ID.
    if not(auth.chainId == 0.u256 or auth.chainId == vmState.com.chainId):
      continue

    # 2. Verify the nonce is less than 2**64 - 1.
    if auth.nonce+1 < auth.nonce:
      continue

    # 3. authority = ecrecover(keccak(MAGIC || rlp([chain_id, address, nonce])), y_parity, r, s]
    let authority = authority(auth).valueOr:
      continue

    # 4. Add authority to accessed_addresses (as defined in EIP-2929.)
    ledger.accessList(authority)

    # 5. Verify the code of authority is either empty or already delegated.
    let code = ledger.getCode(authority)
    if code.len > 0:
      if not parseDelegation(code):
        continue

    # 6. Verify the nonce of authority is equal to nonce.
    if ledger.getNonce(authority) != auth.nonce:
      continue

    # 7. Add PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST gas to the global refund counter if authority exists in the trie.
    if ledger.accountExists(authority):
      gasRefund += PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST

    # 8. Set the code of authority to be 0xef0100 || address. This is a delegation designation.
    if auth.address == zeroAddress:
      ledger.setCode(authority, @[])
    else:
      ledger.setCode(authority, @(addressToDelegation(auth.address)))

    # 9. Increase the nonce of authority by one.
    ledger.setNonce(authority, auth.nonce + 1)

  gasRefund

proc setupHost(call: CallParams, keepStack: bool): TransactionHost =
  let vmState = call.vmState
  vmState.txCtx = TxContext(
    origin         : call.origin.get(call.sender),
    gasPrice       : call.gasPrice,
    versionedHashes: call.versionedHashes,
    blobBaseFee    : getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, vmState.fork),
  )

  # reset global gasRefund counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0

  let
    (intrinsicGas, floorDataGas) = if call.noIntrinsic: (0.GasInt, 0.GasInt)
                                   else: intrinsicGas(call, vmState.fork)
    host = TransactionHost(
      vmState: vmState,
      sysCall: call.sysCall,
      floorDataGas: floorDataGas,
      # All other defaults in `TransactionHost` are fine.
    )

    msg = Message(
      kind:            if call.isCreate:
                         CallKind.Create
                       else:
                         CallKind.Call,
      # flags: {},
      # depth: 0,
      gas:             call.gasLimit - intrinsicGas,
      contractAddress: call.to,
      codeAddress:     call.to,
      sender:          call.sender,
      value:           call.value,
    )

    gasRefund = if call.sysCall: 0
                else: preExecComputation(vmState, call)
    code = if call.isCreate:
             msg.contractAddress = generateContractAddress(call.vmState, CallKind.Create, call.sender)
             CodeBytesRef.init(call.input)
           else:
             msg.data = call.input
             getCallCode(host.vmState, msg.codeAddress)

  host.computation = newComputation(vmState, keepStack, msg, code)
  host.computation.addRefund(gasRefund)
  vmState.captureStart(host.computation, call.sender, call.to,
                       call.isCreate, call.input,
                       call.gasLimit, call.value)

  return host

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

    vmState.mutateLedger:
      db.subBalance(call.sender, call.gasLimit.u256 * call.gasPrice.u256)

      # EIP-4844
      if fork >= FkCancun:
        let blobFee = calcDataFee(call.versionedHashes.len,
          vmState.blockCtx.excessBlobGas, vmState.com, fork)
        db.subBalance(call.sender, blobFee)

proc calculateAndPossiblyRefundGas(host: TransactionHost, call: CallParams): GasInt =
  let
    c = host.computation
    fork = host.vmState.fork

  # EIP-3529: Reduction in refunds
  let MaxRefundQuotient = if fork >= FkLondon:
                            5.GasInt
                          else:
                            2.GasInt

  var gasRemaining = 0.GasInt

  # Calculated gas used, taking into account refund rules.
  if call.noRefund:
    gasRemaining = c.gasMeter.gasRemaining
  else:
    if c.shouldBurnGas:
      c.gasMeter.gasRemaining = 0
    let maxRefund = (call.gasLimit - c.gasMeter.gasRemaining) div MaxRefundQuotient
    let refund = min(c.getGasRefund(), maxRefund)
    c.gasMeter.returnGas(refund)
    gasRemaining = c.gasMeter.gasRemaining

  let gasUsed = call.gasLimit - gasRemaining
  if fork >= FkPrague:
    if host.floorDataGas > gasUsed:
      gasRemaining = call.gasLimit - host.floorDataGas
      c.gasMeter.gasRemaining = gasRemaining

  # Refund for unused gas.
  if gasRemaining > 0 and not call.noGasCharge:
    host.vmState.mutateLedger:
      db.addBalance(call.sender, gasRemaining.u256 * call.gasPrice.u256)

  gasRemaining

proc finishRunningComputation(
    host: TransactionHost, call: CallParams, T: type): T =
  let c = host.computation

  let gasRemaining = calculateAndPossiblyRefundGas(host, call)
  # evm gas used without intrinsic gas
  let evmGasUsed = c.msg.gas - gasRemaining
  host.vmState.captureEnd(c, c.output, evmGasUsed, c.errorOpt)

  when T is CallResult|DebugCallResult:
    # Collecting the result can be unnecessarily expensive when (re)-processing
    # transactions
    if c.isError:
      result.error = c.error.info
    result.gasUsed = call.gasLimit - gasRemaining
    result.output = system.move(c.output)
    result.contractAddress = if call.isCreate: c.msg.contractAddress
                             else: default(Address)

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

  host.computation.execCallOrCreate()
  if not call.sysCall:
    host.computation.postExecComputation()

  finishRunningComputation(host, call, T)
