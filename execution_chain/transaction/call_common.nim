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
  ../evm/[message, precompiles, internals, interpreter_dispatch, evm_errors],
  ../evm/interpreter/op_handlers/oph_helpers,
  ../db/ledger,
  ../common/evmforks,
  ../core/eip4844,
  ../core/eip8037,
   ./eoa_delegation,
   ./call_types

import ../evm/computation

export
  call_types

type
  GasUsed = object
    evmGasUsed: GasInt
    txGasUsed: GasInt
    blockExecutionGasUsed: GasInt
    blockStateGasUsed: GasInt

proc initialAccessListEIP2929(params: CallParams) =
  # EIP2929 initial access list.
  let
    vmState = params.vmState
    tx = params.tx

  if vmState.fork < FkBerlin:
    return

  vmState.mutateLedger:
    ledger.accessList(params.sender)

    # EIP3651 adds coinbase to the list of addresses that should start warm.
    if vmState.fork >= FkShanghai:
      ledger.accessList(vmState.coinbase)

    # Adds the correct subset of precompiles.
    for c in activePrecompiles(vmState.fork):
      ledger.accessList(c)

    # EIP2930 optional access list.
    for account in tx.accessList:
      ledger.accessList(account.address)
      for key in account.storageKeys:
        ledger.accessList(account.address, key.to(UInt256))

proc setupComputation(params: CallParams, keepStack: bool, vmState: BaseVMState, msg: Message): Computation =
  if vmState.hardFork < Amsterdam:
    var
      code = if params.isCreate:
              msg.contractAddress = generateContractAddress(vmState, params.sender)
              CodeBytesRef.init(params.tx.payload)
            else:
              assign(msg.data, params.tx.payload)
              getRecipientCode(vmState, msg)

    if MsgFlags.Delegated in msg.flags:
      # If the `call.to` has a delegation, also warm its target.
      vmState.ledger.accessList(msg.delegateTo)
      code = vmState.readOnlyLedger.getCode(msg.delegateTo)

    return newComputation(vmState, keepStack, msg, code)

  # Delay loading code until interpreter_dispatch.prepareDispatch
  if params.isCreate:
    msg.contractAddress = generateContractAddress(vmState, params.sender)
  newComputation(vmState, keepStack, msg)

proc setupEVM(params: CallParams, keepStack: bool): Computation =
  let
    vmState = params.vmState
    fork = vmState.hardFork
  vmState.txCtx = TxContext(
    origin     : params.sender,
    gasPrice   : params.gasPrice,
    blobBaseFee: getBlobBaseFee(vmState.blockCtx.excessBlobGas, vmState.com, fork),
    tx         : params.tx,
  )

  # reset global gasRefunded counter each time
  # EVM called for a new transaction
  vmState.gasRefunded = 0

  let
    # Prevent underflow which can occur when gasLimit is less than intrinsicGas.
    # Note that this is only a short term fix. In the longer term we need to
    # implement validation on all fields in the Message before executing in the EVM.
    # TODO: Implement full validation on all fields. See related issue: https://github.com/status-im/nimbus-eth1/issues/1524
    tx = params.tx
    evmGas = if tx.gasLimit < params.intrinsic.execution: 0.GasInt
             else: tx.gasLimit - params.intrinsic.execution
    executionGasBudget = TX_GAS_LIMIT - params.intrinsic.execution

  var
    executionGas = evmGas
    stateGasReservoir = 0.GasInt
    executionRefund = 0'i64

  if fork >= Amsterdam:
    executionGas = min(executionGasBudget, evmGas)
    stateGasReservoir = evmGas - executionGas
  else:
    executionRefund = setDelegation(params)

  let
    destination = tx[].destination
    msg = Message(
      kind:              if params.isCreate: CallKind.Create
                         else: CallKind.Call,
      gas:               executionGas,
      stateGasReservoir: stateGasReservoir,
      contractAddress:   destination,
      codeAddress:       destination,
      delegateTo:        destination,
      sender:            params.sender,
      value:             tx.value,
    )
    computation = setupComputation(params, keepStack, vmState, msg)

  if computation.isSuccess:
    computation.addRefund(executionRefund)
    vmState.captureStart(computation, params.sender, destination,
                         params.isCreate, tx.payload,
                         tx.gasLimit, tx.value)
  computation

# FIXME-awkwardFactoring: the factoring out of the pre and
# post parts feels awkward to me, but for now I'd really like
# not to have too much duplicated code between sync and async.
# --Adam

proc prepareToRunComputation(params: CallParams) =
  let
    vmState = params.vmState
    fork = vmState.hardFork
    tx = params.tx

  vmState.mutateLedger:
    if not params.isCreate:
      if vmState.balTrackerEnabled:
        vmState.balTracker.trackIncNonceChange(params.sender)
      ledger.incNonce(params.sender)

    # Charge for gas.
    var gasFee = tx.gasLimit.u256 * params.gasPrice.u256
    if fork >= Cancun:
      # EIP-4844
      gasFee += calcDataFee(tx.versionedHashes.len,
        vmState.blockCtx.excessBlobGas, vmState.com, fork)

    if vmState.balTrackerEnabled:
      vmState.balTracker.trackSubBalanceChange(params.sender, gasFee)
    ledger.subBalance(params.sender, gasFee)

proc calculateAndPossiblyRefundGas(c: Computation, params: CallParams): GasUsed =
  let
    vmState = c.vmState
    fork = c.vmState.fork
    tx = params.tx
    # EIP-3529: Reduction in refunds
    MaxRefundQuotient = if fork >= FkLondon: 5.GasInt
                        else: 2.GasInt

  if c.shouldBurnGas:
    c.gasMeter.burnGas()

  # Calculated gas used, taking into account refund rules.
  let
    gasUsedBeforeRefund = tx.gasLimit - c.gasMeter.executionGasLeft - c.gasMeter.stateGasLeft
    gasRefund = min(gasUsedBeforeRefund div MaxRefundQuotient, c.getGasRefund())
    gasUsedAfterRefund = gasUsedBeforeRefund - gasRefund

  var
    txGasUsed = gasUsedAfterRefund
    blockExecutionGasUsed = txGasUsed
    blockStateGasUsed = 0.GasInt

  if fork >= FkPrague:
    txGasUsed = max(gasUsedAfterRefund, params.intrinsic.floorDataGas)
    if fork >= FkAmsterdam:
      let stateGasUsed = c.vmState.authStateGasUsed + c.frameStateGasUsed()
      blockStateGasUsed = GasInt(max(0, stateGasUsed))
      blockExecutionGasUsed = max(gasUsedBeforeRefund - blockStateGasUsed, params.intrinsic.floorDataGas)

  # Refund for unused gas.
  let txGasLeft = tx.gasLimit - txGasUsed
  if txGasLeft > 0:
    let gasRefundAmount = txGasLeft.u256 * params.gasPrice.u256
    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddBalanceChange(params.sender, gasRefundAmount)
    vmState.mutateLedger:
      ledger.addBalance(params.sender, gasRefundAmount, checkEmptyAccount = fork < FkParis)

  GasUsed(
    evmGasUsed: c.msg.gas - txGasLeft,
    txGasUsed: txGasUsed,
    blockExecutionGasUsed: blockExecutionGasUsed,
    blockStateGasUsed: blockStateGasUsed,
  )

proc finishRunningComputation(
    c: Computation, params: CallParams, T: type): T =
  let
    gasUsed = calculateAndPossiblyRefundGas(c, params)

  # evm gas used without intrinsic gas
  c.vmState.captureEnd(c, c.output, gasUsed.evmGasUsed, c.errorOpt)

  when T is CallResult|DebugCallResult:
    # Collecting the result can be unnecessarily expensive when (re)-processing
    # transactions
    if c.isError:
      result.error = c.error.info
    result.gasUsed = gasUsed.txGasUsed
    result.output = system.move(c.output)
    result.contractAddress = if params.isCreate: c.msg.contractAddress
                             else: default(addresses.Address)

    when T is DebugCallResult:
      result.stack = move(c.finalStack)
      result.memory = move(c.memory)
      if c.isSuccess:
        result.logEntries = move(c.logEntries)
  elif T is LogResult:
    result.gasUsed = gasUsed.txGasUsed
    result.blockExecutionGasUsed = gasUsed.blockExecutionGasUsed
    result.blockStateGasUsed = gasUsed.blockStateGasUsed
    if c.isSuccess:
      result.logEntries = move(c.logEntries)
  elif T is VoidResult:
    discard
  else:
    {.error: "Unknown computation output".}

proc prepareDispatch(params: CallParams, c: Computation): EvmResultVoid =
  let
    vmState = c.vmState
    ledger = vmState.ledger
    tx = params.tx

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(c.msg.contractAddress)

  var
    code =
      if params.isCreate:
        if ledger.originalAccountEmpty(c.msg.contractAddress):
          ? c.gasMeter.chargeStateGas(CREATE_ACCOUNT_STATE_GAS, "prepareDispatch create new account")
        CodeBytesRef.init(tx.payload)
      else:
        if tx.value.isZero.not and not ledger.isAccountAlive(c.msg.contractAddress):
          ? c.gasMeter.chargeStateGas(CREATE_ACCOUNT_STATE_GAS, "prepareDispatch call new account")
        assign(c.msg.data, tx.payload)
        getRecipientCode(vmState, c.msg)

  if MsgFlags.Delegated in c.msg.flags:
    # The delegated account access must be charged before its code is read,
    # or an OOG here would wrongly add the target account to the witness.
    let delegatedGas = c.gasEip8038AccountCheck(c.msg.delegateTo)
    ? c.gasMeter.consumeGas(delegatedGas, "prepareDispatch delegatedGas")

    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(c.msg.delegateTo)
    code = vmState.readOnlyLedger.getCode(c.msg.delegateTo)

  c.setCode(code)
  ok()

proc authAndDelegation(params: CallParams, c: Computation): EvmResultVoid =
  ? params.setDelegation(c)
  c.vmState.authStateGasUsed = c.frameStateGasUsed()
  c.msg.stateGasReservoir = c.gasMeter.stateGasLeft
  c.gasMeter.stateGasSpilled = 0
  params.prepareDispatch(c)

proc topFrameAuthAndDelegation(params: CallParams, c: Computation): bool =
  let
    prepReservoir = c.msg.stateGasReservoir

  c.beginSavePoint()
  params.authAndDelegation(c).isOkOr:
    c.rollback()
    c.msg.stateGasReservoir = prepReservoir
    c.vmState.authStateGasUsed = 0
    c.refillFrameStateGas()
    c.setError($error.code, true)
    return false

  c.commit()
  true

proc preExecComputation(c: Computation, params: CallParams) =
  if params.isCreate:
    if not c.incrementNonce():
      return

    if c.fork >= FkAmsterdam:
      if not params.topFrameAuthAndDelegation(c):
        return

    if not c.accountDeployable():
      c.refillFrameStateGas()
      return

    return

  if c.fork >= FkAmsterdam:
    if not params.topFrameAuthAndDelegation(c):
      return

proc runComputation*(params: CallParams, T: type): T =
  prepareToRunComputation(params)
  initialAccessListEIP2929(params)

  let
    c = setupEVM(params, keepStack = T is DebugCallResult)

  c.preExecComputation(params)
  if c.isSuccess:
    c.execCallOrCreate()
  else:
    # execCallOrCreate normally disposes the computation, dispose here too
    # otherwise the EVM stack leaks.
    c.dispose()
  # postExecComputation must also run when preExecComputation fails:
  # it records the outcome in vmState.status, which the receipt reads.
  # Skipping it leaves the previous transaction's status in place and
  # a top-frame failure would be receipted as successful, diverging on
  # receiptsRoot.
  c.postExecComputation()

  finishRunningComputation(c, params, T)
