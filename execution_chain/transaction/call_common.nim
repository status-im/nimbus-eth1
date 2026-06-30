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
  stew/assign2,
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

proc setDelegation(call: CallParams): (int64, int64) =
  var
    regularRefund = 0'i64
    stateRefund = 0'i64
    passCount = 0

  let
    vmState = call.vmState
    ledger = vmState.ledger

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
    let
      code = ledger.getCode(authority)
    if code.len > 0:
      if not isDelegation(code):
        continue

    # 6. Verify the nonce of authority is equal to nonce.
    if ledger.getNonce(authority) != auth.nonce:
      continue

    inc passCount

    if vmState.fork >= FkAmsterdam:
      # 7. Add PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST gas to the global refund counter if authority exists in the trie.
      if ledger.accountExists(authority):
        stateRefund += CREATE_ACCOUNT_STATE_GAS
        regularRefund += ACCOUNT_WRITE_8038

      # 8. Set the code of authority to be 0xef0100 || address. This is a delegation designation.
      let
        preStateAuthorityCode = ledger.getOriginalCode(authority)
        delegatedBeforeTx = isDelegation(preStateAuthorityCode)
        delegatedNow = isDelegation(code)

      let authCode =
        if auth.address == zeroAddress:
          stateRefund += AUTH_BASE_STATE_GAS
          if delegatedNow and not delegatedBeforeTx:
            stateRefund += AUTH_BASE_STATE_GAS
          # @[] will cause wasm/emscripten/arc/orc ICE with nim v2.2.10
          # https://github.com/nim-lang/Nim/issues/25945
          newSeq[byte]()
        else:
          if delegatedNow or delegatedBeforeTx:
            stateRefund += AUTH_BASE_STATE_GAS
          @(addressToDelegation(auth.address))

      if vmState.balTrackerEnabled:
        vmState.balTracker.trackCodeChange(authority, authCode)
      ledger.setCode(authority, authCode)
    else:
      # 7. Add PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST gas to the global refund counter if authority exists in the trie.
      if ledger.accountExists(authority):
        regularRefund += PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST

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

  if vmState.fork >= FkAmsterdam:
    let refundCount = call.authorizationList.len - passCount
    regularRefund += ACCOUNT_WRITE_8038 * refundCount
    stateRefund += (AUTH_BASE_STATE_GAS + CREATE_ACCOUNT_STATE_GAS) * refundCount

  (regularRefund, stateRefund)

proc setupComputation(call: CallParams, regularRefund: int64, stateRefund: int64, keepStack: bool): Computation =
  let
    vmState = call.vmState
    fork = vmState.hardFork
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
    isAmsterdamOrLater = fork >= Amsterdam
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
    stateGas = executionGas - gasLeft + stateRefund.GasInt

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
      delegateTo:      call.to,
      sender:          call.sender,
      value:           call.value,
    )

    code = if call.isCreate:
             msg.contractAddress = generateContractAddress(vmState, call.sender)
             CodeBytesRef.init(call.input)
           else:
             assign(msg.data, call.input)
             getCallCode(vmState, msg)

    computation = newComputation(vmState, keepStack, msg, code)

  computation.addRefund(regularRefund)

  vmState.captureStart(computation, call.sender, call.to,
                       call.isCreate, call.input,
                       call.gasLimit, call.value)
  computation

# FIXME-awkwardFactoring: the factoring out of the pre and
# post parts feels awkward to me, but for now I'd really like
# not to have too much duplicated code between sync and async.
# --Adam

proc prepareToRunComputation(call: CallParams) =
  let
    vmState = call.vmState
    fork = vmState.hardFork

  vmState.mutateLedger:
    if not call.isCreate:
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackIncNonceChange(call.sender)
      ledger.incNonce(call.sender)

    # Charge for gas.
    var gasFee = call.gasLimit.u256 * call.gasPrice.u256
    if fork >= Cancun:
      # EIP-4844
      gasFee += calcDataFee(call.versionedHashes.len,
        vmState.blockCtx.excessBlobGas, vmState.com, fork)

    if vmState.balTrackerEnabled:
      vmState.balTracker.trackSubBalanceChange(call.sender, gasFee)
    ledger.subBalance(call.sender, gasFee)

proc calculateAndPossiblyRefundGas(c: Computation, call: CallParams, stateRefund: int64): GasUsed =
  let
    vmState = c.vmState
    fork = c.vmState.fork
    # EIP-3529: Reduction in refunds
    MaxRefundQuotient = if fork >= FkLondon: 5.GasInt
                        else: 2.GasInt

  var
    stateGasRefund = stateRefund

  if c.shouldBurnGas:
    c.gasMeter.burnGas()

  if c.fork >= FkAmsterdam:
    if call.isCreate:
      if c.isError or MsgFlags.TargetAlive in c.msg.flags:
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
    blockStateGasUsed = GasInt(max(0, call.intrinsic.state.int64 + c.gasMeter.stateGasUsed - stateGasRefund))
    blockRegularGasUsed = txGasUsedBeforeRefund - blockStateGasUsed
    debug "EIP-8037 gas accounting",
      intrinsicRegular = call.intrinsic.regular,
      intrinsicState = call.intrinsic.state,
      regularGasUsed = c.gasMeter.regularGasUsed,
      stateGasUsed = c.gasMeter.stateGasUsed,
      gasRemaining = c.gasMeter.gasRemaining,
      stateGasLeft = c.gasMeter.stateGasLeft,
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
      ledger.addBalance(call.sender, gasRefundAmount, checkEmptyAccount = fork < FkParis)

  GasUsed(
    evmGasUsed: c.msg.gas - txGasLeft,
    txGasUsed: txGasUsed,
    blockRegularGasUsed: blockRegularGasUsed,
    blockStateGasUsed: blockStateGasUsed,
  )

proc finishRunningComputation(
    c: Computation, call: CallParams, stateRefund: int64, T: type): T =
  let
    gasUsed = calculateAndPossiblyRefundGas(c, call, stateRefund)

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
  elif T is VoidResult:
    discard
  else:
    {.error: "Unknown computation output".}

proc runComputation*(call: CallParams, T: type): T =
  prepareToRunComputation(call)
  initialAccessListEIP2929(call)

  let
    (regularRefund, stateRefund) = setDelegation(call)
    c = setupComputation(call, regularRefund, stateRefund, keepStack = T is DebugCallResult)

  # Pre-execution sanity checks
  c.preExecComputation()
  if c.isSuccess:
    c.execCallOrCreate()
    c.postExecComputation()
  finishRunningComputation(c, call, stateRefund, T)
