# Nimbus - Common entry point to the EVM from all different callers
#
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/eth_types, stint,
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
    floorDataGas:    GasInt

  GasUsed = object
    evmGasUsed: GasInt
    txGasUsed: GasInt
    blockGasUsedInTx: GasInt

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
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackAddressAccess(call.to)
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
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackIncNonceChange(call.sender)
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
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(authority)
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
    let authCode =
      if auth.address == zeroAddress:
        @[]
      else:
        @(addressToDelegation(auth.address))
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackCodeChange(authority, authCode)
    ledger.setCode(authority, authCode)

    # 9. Increase the nonce of authority by one.
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackNonceChange(authority, auth.nonce + 1)
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
    (intrinsicGas, floorDataGas) = if call.sysCall: (0.GasInt, 0.GasInt)
                                   else: intrinsicGas(call, vmState.fork)
    host = TransactionHost(
      vmState: vmState,
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
      # Prevent underflow which can occur when gasLimit is less than intrinsicGas.
      # Note that this is only a short term fix. In the longer term we need to
      # implement validation on all fields in the Message before executing in the EVM.
      # TODO: Implement full validation on all fields. See related issue: https://github.com/status-im/nimbus-eth1/issues/1524
      gas:             if call.gasLimit < intrinsicGas: 0.GasInt else: call.gasLimit - intrinsicGas,
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
  initialAccessListEIP2929(call)

  # Charge for gas.
  let
    vmState = host.vmState
    fork = vmState.fork

  vmState.mutateLedger:
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackSubBalanceChange(call.sender, call.gasLimit.u256 * call.gasPrice.u256)
    db.subBalance(call.sender, call.gasLimit.u256 * call.gasPrice.u256)

    # EIP-4844
    if fork >= FkCancun:
      let blobFee = calcDataFee(call.versionedHashes.len,
        vmState.blockCtx.excessBlobGas, vmState.com, fork)
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackSubBalanceChange(call.sender, blobFee)
      db.subBalance(call.sender, blobFee)

proc calculateAndPossiblyRefundGas(host: TransactionHost, call: CallParams): GasUsed =
  let
    c = host.computation
    vmState = host.vmState
    fork = host.vmState.fork

  # EIP-3529: Reduction in refunds
  let MaxRefundQuotient = if fork >= FkLondon:
                            5.GasInt
                          else:
                            2.GasInt
  if c.shouldBurnGas:
    c.gasMeter.gasRemaining = 0

  # Calculated gas used, taking into account refund rules.
  let
    txGasUsedBeforeRefund = call.gasLimit - c.gasMeter.gasRemaining
    maxRefund = txGasUsedBeforeRefund div MaxRefundQuotient
    txGasRefund = min(c.getGasRefund(), maxRefund)
    txGasUsedAfterRefund = txGasUsedBeforeRefund - txGasRefund

  var
    txGasUsed = txGasUsedAfterRefund
    blockGasUsedInTx = txGasUsed

  if fork >= FkPrague:
    txGasUsed = max(txGasUsedAfterRefund, host.floorDataGas)
    blockGasUsedInTx = txGasUsed

  # Refund for unused gas.
  let txGasLeft = call.gasLimit - txGasUsed
  if txGasLeft > 0:
    let gasRefundAmount = txGasLeft.u256 * call.gasPrice.u256
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddBalanceChange(call.sender, gasRefundAmount)
    vmState.mutateLedger:
      db.addBalance(call.sender, gasRefundAmount)

  GasUsed(
    evmGasUsed: c.msg.gas - txGasLeft,
    txGasUsed: txGasUsed,
    blockGasUsedInTx: blockGasUsedInTx,
  )

proc sysCallGasUsed(host: TransactionHost, call: CallParams): GasUsed =
  let
    c = host.computation
    txGasUsed = call.gasLimit - c.gasMeter.gasRemaining
  GasUsed(
    evmGasUsed: c.msg.gas - c.gasMeter.gasRemaining,
    txGasUsed: txGasUsed,
    blockGasUsedInTx: txGasUsed,
  )

proc finishRunningComputation(
    host: TransactionHost, call: CallParams, T: type): T =
  let
    c = host.computation
    gasUsed = if call.sysCall: sysCallGasUsed(host, call)
              else: calculateAndPossiblyRefundGas(host, call)

  # evm gas used without intrinsic gas
  host.vmState.captureEnd(c, c.output, gasUsed.evmGasUsed, c.errorOpt)

  when T is CallResult|DebugCallResult:
    # Collecting the result can be unnecessarily expensive when (re)-processing
    # transactions
    if c.isError:
      result.error = c.error.info
    result.gasUsed = gasUsed.txGasUsed
    result.output = system.move(c.output)
    result.contractAddress = if call.isCreate: c.msg.contractAddress
                             else: default(addresses.Address)

    when T is DebugCallResult:
      result.stack = move(c.finalStack)
      result.memory = move(c.memory)
      if c.isSuccess:
        result.logEntries = move(c.logEntries)
  elif T is GasInt:
    result = gasUsed.txGasUsed
  elif T is LogResult:
    result.gasUsed = gasUsed.txGasUsed
    result.blockGasUsed = gasUsed.blockGasUsedInTx
    if c.isSuccess:
      result.logEntries = move(c.logEntries)
  elif T is string:
    if c.isError:
      result = c.error.info
  elif T is seq[byte]:
    result = move(c.output)
  elif T is OutputResult:
    if c.isError:
      result.error = c.error.info
    result.output = move(c.output)
  else:
    {.error: "Unknown computation output".}

proc runComputation*(call: CallParams, T: type): T =
  let host = setupHost(call, keepStack = T is DebugCallResult)
  if not call.sysCall:
    prepareToRunComputation(host, call)

  # Pre-execution sanity checks
  host.computation.preExecComputation()
  if host.computation.isError:
    return finishRunningComputation(host, call, T)

  host.computation.execCallOrCreate()
  if not call.sysCall:
    host.computation.postExecComputation()

  finishRunningComputation(host, call, T)
