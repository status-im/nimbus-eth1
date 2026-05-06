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
  chronicles,
  ../evm/[types, state],
  ../evm/[message, precompiles, internals, interpreter_dispatch],
  ../db/ledger,
  ../common/evmforks,
  ../core/[eip4844, eip7702, eip8037],
  ./call_types

import ../evm/computation

export
  call_types

type
  TransactionHost = ref object
    vmState:         BaseVMState
    computation:     Computation
    floorDataGas:    GasInt
    intrinsicRegularGas: GasInt
    intrinsicStateGas: GasInt

  GasUsed = object
    evmGasUsed: GasInt
    txGasUsed: GasInt
    blockRegularGasUsed: GasInt
    blockStateGasUsed: GasInt

proc initialAccessListEIP2929(call: CallParams) =
  # EIP2929 initial access list.
  let vmState = call.vmState
  if vmState.fork < FkBerlin:
    return

  vmState.mutateLedger:
    ledger.accessList(call.sender)
    # For contract creations the EVM will add the contract address to the
    # access list itself, after calculating the new contract address.
    if not call.isCreate:
      ledger.accessList(call.to)
      # If the `call.to` has a delegation, also warm its target.
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackAddressAccess(call.to)
      let target = parseDelegationAddress(ledger.getCode(call.to))
      if target.isSome:
        ledger.accessList(target[])

    # EIP3651 adds coinbase to the list of addresses that should start warm.
    if vmState.fork >= FkShanghai:
      ledger.accessList(vmState.coinbase)

    # Adds the correct subset of precompiles.
    for c in activePrecompiles(vmState.fork):
      ledger.accessList(c)

    # EIP2930 optional access list.
    for account in call.accessList:
      ledger.accessList(account.address)
      for key in account.storageKeys:
        ledger.accessList(account.address, key.to(UInt256))

proc preExecComputation(vmState: BaseVMState, call: CallParams): int64 =
  var gasRefund = 0'i64
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
      if vmState.fork >= FkAmsterdam:
        gasRefund += int64(CREATE_ACCOUNT_STATE_GAS)
      else:
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
  let
    vmState = call.vmState
    fork = vmState.fork
  vmState.txCtx = TxContext(
    origin         : call.origin.get(call.sender),
    gasPrice       : call.gasPrice,
    versionedHashes: call.versionedHashes,
    blobBaseFee    : getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, fork),
  )

  # reset global gasRefund counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0

  let
    isAmsterdamOrLater = fork >= FkAmsterdam
    intrinsic = call.intrinsic
    gasRefund = if call.sysCall: 0'i64
                else: preExecComputation(vmState, call)
    intrinsicGas = intrinsic.regular + intrinsic.state

    # Prevent underflow which can occur when gasLimit is less than intrinsicGas.
    # Note that this is only a short term fix. In the longer term we need to
    # implement validation on all fields in the Message before executing in the EVM.
    # TODO: Implement full validation on all fields. See related issue: https://github.com/status-im/nimbus-eth1/issues/1524
    executionGas = if call.gasLimit < intrinsicGas: 0.GasInt else: call.gasLimit - intrinsicGas
    regularGasBudget = TX_GAS_LIMIT - intrinsic.regular

  var
    gasLeft = executionGas
    intrinsicStateGas = 0.GasInt
    stateGas = 0.GasInt

  if isAmsterdamOrLater:
    gasLeft = min(regularGasBudget, executionGas)
    intrinsicStateGas = intrinsic.state
    stateGas = executionGas - gasLeft + gasRefund.GasInt

  let
    host = TransactionHost(
      vmState: vmState,
      floorDataGas: intrinsic.floorDataGas,
      intrinsicRegularGas: intrinsic.regular,
      intrinsicStateGas: intrinsicStateGas,
      # All other defaults in `TransactionHost` are fine.
    )

    msg = Message(
      kind:            if call.isCreate:
                         CallKind.Create
                       else:
                         CallKind.Call,
      # flags: {},
      # depth: 0,
      gas:             gasLeft,
      stateGas:        stateGas,
      contractAddress: call.to,
      codeAddress:     call.to,
      sender:          call.sender,
      value:           call.value,
    )

    code = if call.isCreate:
             msg.contractAddress = generateContractAddress(call.vmState, CallKind.Create, call.sender)
             CodeBytesRef.init(call.input)
           else:
             msg.data = call.input
             getCallCode(host.vmState, msg.codeAddress)

  host.computation = newComputation(vmState, keepStack, msg, code)
  if not isAmsterdamOrLater:
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
    ledger.subBalance(call.sender, call.gasLimit.u256 * call.gasPrice.u256)

    # EIP-4844
    if fork >= FkCancun:
      let blobFee = calcDataFee(call.versionedHashes.len,
        vmState.blockCtx.excessBlobGas, vmState.com, fork)
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackSubBalanceChange(call.sender, blobFee)
      ledger.subBalance(call.sender, blobFee)

proc calcSelfDestructRefundStateGas(c: Computation) =
  let
    ledger = c.vmState.ledger

  var
    refundSum = 0

  for refund in newlyCreatedSelfDestructRefund(ledger):
    refundSum += CREATE_ACCOUNT_STATE_GAS
    refundSum += STATE_GAS_STORAGE_SET * refund.createdSlots
    refundSum += COST_PER_STATE_BYTE * refund.codeLen

  c.gasMeter.selfDestructRefundStateGas(refundSum.GasInt)

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
    c.gasMeter.burnGas()

  if c.fork >= FkAmsterdam:
    if c.isSuccess:
      # https://github.com/ethereum/execution-specs/pull/2707/changes
      c.calcSelfDestructRefundStateGas()
    else:
      # https://github.com/ethereum/execution-specs/pull/2689/changes
      c.gasMeter.returnAllStateGas()

  # Calculated gas used, taking into account refund rules.
  let
    txGasUsedBeforeRefund = call.gasLimit - c.gasMeter.gasRemaining - c.gasMeter.stateGasLeft
    maxRefund = txGasUsedBeforeRefund div MaxRefundQuotient
    txGasRefund = min(c.getGasRefund(), maxRefund)
    txGasUsedAfterRefund = txGasUsedBeforeRefund - txGasRefund

  var
    txGasUsed = txGasUsedAfterRefund
    blockRegularGasUsed = txGasUsed
    blockStateGasUsed = 0.GasInt

  if fork >= FkAmsterdam:
    txGasUsed = max(txGasUsedAfterRefund, host.floorDataGas)
    let txRegularGas = host.intrinsicRegularGas + c.gasMeter.regularGasUsed
    blockRegularGasUsed = max(txRegularGas, host.floorDataGas)
    blockStateGasUsed = host.intrinsicStateGas + c.gasMeter.stateGasUsed
    debug "EIP-8037 gas accounting",
      intrinsicRegular = host.intrinsicRegularGas,
      intrinsicState = host.intrinsicStateGas,
      regularGasUsed = c.gasMeter.regularGasUsed,
      stateGasUsed = c.gasMeter.stateGasUsed,
      gasRemaining = c.gasMeter.gasRemaining,
      stateGasLeft = c.gasMeter.stateGasLeft,
      txRegularGas = txRegularGas,
      blockRegularGasUsed = blockRegularGasUsed,
      blockStateGasUsed = blockStateGasUsed,
      txGasUsed = txGasUsed,
      floorDataGas = host.floorDataGas
  elif fork >= FkPrague:
    txGasUsed = max(txGasUsedAfterRefund, host.floorDataGas)
    blockRegularGasUsed = txGasUsed

  # Refund for unused gas.
  let txGasLeft = call.gasLimit - txGasUsed
  if txGasLeft > 0:
    let gasRefundAmount = txGasLeft.u256 * call.gasPrice.u256
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddBalanceChange(call.sender, gasRefundAmount)
    vmState.mutateLedger:
      ledger.addBalance(call.sender, gasRefundAmount)

  GasUsed(
    evmGasUsed: c.msg.gas - txGasLeft,
    txGasUsed: txGasUsed,
    blockRegularGasUsed: blockRegularGasUsed,
    blockStateGasUsed: blockStateGasUsed,
  )

proc sysCallGasUsed(host: TransactionHost, call: CallParams): GasUsed =
  let
    c = host.computation
    txGasUsed = call.gasLimit - c.gasMeter.gasRemaining - c.gasMeter.stateGasLeft
  GasUsed(
    evmGasUsed: c.msg.gas - c.gasMeter.gasRemaining - c.gasMeter.stateGasLeft,
    txGasUsed: txGasUsed,
    blockRegularGasUsed: txGasUsed,
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
    result.blockRegularGasUsed = gasUsed.blockRegularGasUsed
    result.blockStateGasUsed = gasUsed.blockStateGasUsed
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
  elif T is void:
    discard
  else:
    {.error: "Unknown computation output".}

proc runComputation*(call: CallParams, T: type): T =
  let host = setupHost(call, keepStack = T is DebugCallResult)
  if not call.sysCall:
    prepareToRunComputation(host, call)

  # Pre-execution sanity checks
  host.computation.preExecComputation()
  if host.computation.isError:
    when T is void:
      finishRunningComputation(host, call, T)
      return
    else:
      return finishRunningComputation(host, call, T)

  host.computation.execCallOrCreate()
  if not call.sysCall:
    host.computation.postExecComputation()

  finishRunningComputation(host, call, T)
