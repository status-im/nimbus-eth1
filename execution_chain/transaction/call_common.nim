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

proc preExecComputation(call: CallParams): int64 =
  var gasRefund = 0'i64
  let
    vmState = call.vmState
    ledger = vmState.ledger

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
    if vmState.fork >= FkAmsterdam:
      if ledger.accountExists(authority):
        gasRefund += CREATE_ACCOUNT_STATE_GAS
      if code.len > 0:
        # https://github.com/ethereum/execution-specs/commit/a0a1ed10f32bd60d4837566aabc9ee2cd2a8b88a
        # Existing delegation indicator: overwrite in place, no new state bytes added.
        gasRefund += STATE_BYTES_PER_AUTH_BASE * COST_PER_STATE_BYTE
    else:
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

proc setupComputation(call: CallParams, gasRefund: int64, keepStack: bool): Computation =
  let
    vmState = call.vmState
    fork = vmState.fork
  vmState.txCtx = TxContext(
    origin         : call.sender,
    gasPrice       : call.gasPrice,
    versionedHashes: call.versionedHashes,
    blobBaseFee    : getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, fork),
  )

  # reset global gasRefunded counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0

  let
    isAmsterdamOrLater = fork >= FkAmsterdam
    intrinsicGas = call.intrinsic.regular + call.intrinsic.state

    # Prevent underflow which can occur when gasLimit is less than intrinsicGas.
    # Note that this is only a short term fix. In the longer term we need to
    # implement validation on all fields in the Message before executing in the EVM.
    # TODO: Implement full validation on all fields. See related issue: https://github.com/status-im/nimbus-eth1/issues/1524
    executionGas = if call.gasLimit < intrinsicGas: 0.GasInt else: call.gasLimit - intrinsicGas
    regularGasBudget = TX_GAS_LIMIT - call.intrinsic.regular

  var
    gasLeft = executionGas
    stateGas = 0.GasInt

  if isAmsterdamOrLater:
    gasLeft = min(regularGasBudget, executionGas)
    stateGas = executionGas - gasLeft + gasRefund.GasInt

  let
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
             msg.contractAddress = generateContractAddress(vmState, CallKind.Create, call.sender)
             CodeBytesRef.init(call.input)
           else:
             msg.data = call.input
             getCallCode(vmState, msg.codeAddress)

    computation = newComputation(vmState, keepStack, msg, code)

  if not isAmsterdamOrLater:
    computation.addRefund(gasRefund)
  vmState.captureStart(computation, call.sender, call.to,
                       call.isCreate, call.input,
                       call.gasLimit, call.value)
  computation

# FIXME-awkwardFactoring: the factoring out of the pre and
# post parts feels awkward to me, but for now I'd really like
# not to have too much duplicated code between sync and async.
# --Adam

proc prepareToRunComputation(c: Computation, call: CallParams) =
  # Must come after `setupComputation` for correct fork.
  initialAccessListEIP2929(call)

  # Charge for gas.
  let
    vmState = c.vmState
    fork = vmState.fork

  vmState.mutateLedger:
    let gasFee = call.gasLimit.u256 * call.gasPrice.u256
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackSubBalanceChange(call.sender, gasFee)
    ledger.subBalance(call.sender, gasFee)

    # EIP-4844
    if fork >= FkCancun:
      let blobFee = calcDataFee(call.versionedHashes.len,
        vmState.blockCtx.excessBlobGas, vmState.com, fork)
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackSubBalanceChange(call.sender, blobFee)
      ledger.subBalance(call.sender, blobFee)

proc calculateAndPossiblyRefundGas(c: Computation, call: CallParams, gasRefund: int64): GasUsed =
  let
    vmState = c.vmState
    fork = c.vmState.fork
    # EIP-3529: Reduction in refunds
    MaxRefundQuotient = if fork >= FkLondon: 5.GasInt
                        else: 2.GasInt

  var
    stateGasRefund = gasRefund.GasInt

  if c.shouldBurnGas:
    c.gasMeter.burnGas()

  if c.fork >= FkAmsterdam:
    if c.isError:
      # https://github.com/ethereum/execution-specs/pull/2689/changes
      c.gasMeter.returnAllStateGas()
      # https://github.com/ethereum/execution-specs/commit/eb80b438a39d188fddf372ef5632123ca3ee238e
      if call.isCreate:
        c.gasMeter.returnStateGas(CREATE_ACCOUNT_STATE_GAS)
        stateGasRefund += CREATE_ACCOUNT_STATE_GAS

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
    txGasUsed = max(txGasUsedAfterRefund, call.intrinsic.floorDataGas)
    let
      txRegularGas = call.intrinsic.regular + c.gasMeter.regularGasUsed
    blockRegularGasUsed = max(txRegularGas, call.intrinsic.floorDataGas)
    blockStateGasUsed = call.intrinsic.state - stateGasRefund + c.gasMeter.stateGasUsed
    debug "EIP-8037 gas accounting",
      intrinsicRegular = call.intrinsic.regular,
      intrinsicState = call.intrinsic.state,
      regularGasUsed = c.gasMeter.regularGasUsed,
      stateGasUsed = c.gasMeter.stateGasUsed,
      gasRemaining = c.gasMeter.gasRemaining,
      stateGasLeft = c.gasMeter.stateGasLeft,
      txRegularGas = txRegularGas,
      blockRegularGasUsed = blockRegularGasUsed,
      blockStateGasUsed = blockStateGasUsed,
      txGasUsed = txGasUsed,
      floorDataGas = call.intrinsic.floorDataGas
  elif fork >= FkPrague:
    txGasUsed = max(txGasUsedAfterRefund, call.intrinsic.floorDataGas)
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

proc finishRunningComputation(
    c: Computation, call: CallParams, gasRefund: int64, T: type): T =
  let
    gasUsed = calculateAndPossiblyRefundGas(c, call, gasRefund)

  # evm gas used without intrinsic gas
  c.vmState.captureEnd(c, c.output, gasUsed.evmGasUsed, c.errorOpt)

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
  elif T is LogResult:
    result.gasUsed = gasUsed.txGasUsed
    result.blockRegularGasUsed = gasUsed.blockRegularGasUsed
    result.blockStateGasUsed = gasUsed.blockStateGasUsed
    if c.isSuccess:
      result.logEntries = move(c.logEntries)
  else:
    {.error: "Unknown computation output".}

proc runComputation*(call: CallParams, T: type): T =
  let
    gasRefund = preExecComputation(call)
    c = setupComputation(call, gasRefund, keepStack = T is DebugCallResult)

  prepareToRunComputation(c, call)
  # Pre-execution sanity checks
  c.preExecComputation()
  if c.isSuccess:
    c.execCallOrCreate()
    c.postExecComputation()
  finishRunningComputation(c, call, gasRefund, T)
