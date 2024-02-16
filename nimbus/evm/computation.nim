# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  ".."/[db/ledger, constants],
  "."/[code_stream, memory, message, stack, state],
  "."/[types],
  ./interpreter/[gas_meter, gas_costs, op_codes],
  ../common/[common, evmforks],
  ../utils/utils,
  stew/byteutils,
  chronicles, chronos,
  eth/[keys],
  sets

export
  common

logScope:
  topics = "vm computation"

when defined(evmc_enabled):
  import
    evmc/evmc,
    evmc_helpers,
    evmc_api,
    stew/ptrops

  export
    evmc,
    evmc_helpers,
    evmc_api,
    ptrops

const
  evmc_enabled* = defined(evmc_enabled)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc generateContractAddress(c: Computation, salt: ContractSalt): EthAddress =
  if c.msg.kind == EVMC_CREATE:
    let creationNonce = c.vmState.readOnlyStateDB().getNonce(c.msg.sender)
    result = generateAddress(c.msg.sender, creationNonce)
  else:
    result = generateSafeAddress(c.msg.sender, salt, c.msg.data)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template getCoinbase*(c: Computation): EthAddress =
  when evmc_enabled:
    c.host.getTxContext().block_coinbase
  else:
    c.vmState.coinbase

template getTimestamp*(c: Computation): uint64 =
  when evmc_enabled:
    cast[uint64](c.host.getTxContext().block_timestamp)
  else:
    c.vmState.blockCtx.timestamp.uint64

template getBlockNumber*(c: Computation): UInt256 =
  when evmc_enabled:
    c.host.getTxContext().block_number.u256
  else:
    c.vmState.blockNumber.blockNumberToVmWord

template getDifficulty*(c: Computation): DifficultyInt =
  when evmc_enabled:
    UInt256.fromEvmc c.host.getTxContext().block_prev_randao
  else:
    c.vmState.difficultyOrPrevRandao

template getGasLimit*(c: Computation): GasInt =
  when evmc_enabled:
    c.host.getTxContext().block_gas_limit.GasInt
  else:
    c.vmState.blockCtx.gasLimit

template getBaseFee*(c: Computation): UInt256 =
  when evmc_enabled:
    UInt256.fromEvmc c.host.getTxContext().block_base_fee
  else:
    c.vmState.blockCtx.fee.get(0.u256)

template getChainId*(c: Computation): uint =
  when evmc_enabled:
    UInt256.fromEvmc(c.host.getTxContext().chain_id).truncate(uint)
  else:
    c.vmState.com.chainId.uint

template getOrigin*(c: Computation): EthAddress =
  when evmc_enabled:
    c.host.getTxContext().tx_origin
  else:
    c.vmState.txCtx.origin

template getGasPrice*(c: Computation): GasInt =
  when evmc_enabled:
    UInt256.fromEvmc(c.host.getTxContext().tx_gas_price).truncate(GasInt)
  else:
    c.vmState.txCtx.gasPrice

template getVersionedHash*(c: Computation, index: int): VersionedHash =
  when evmc_enabled:
    cast[ptr UncheckedArray[VersionedHash]](c.host.getTxContext().blob_hashes)[index]
  else:
    c.vmState.txCtx.versionedHashes[index]

template getVersionedHashesLen*(c: Computation): int =
  when evmc_enabled:
    c.host.getTxContext().blob_hashes_count.int
  else:
    c.vmState.txCtx.versionedHashes.len

template getBlobBaseFee*(c: Computation): UInt256 =
  when evmc_enabled:
    UInt256.fromEvmc c.host.getTxContext().blob_base_fee
  else:
    c.vmState.txCtx.blobBaseFee

proc getBlockHash*(c: Computation, number: UInt256): Hash256
                   {.gcsafe, raises: [CatchableError].} =
  when evmc_enabled:
    let
      blockNumber = c.host.getTxContext().block_number.u256
      ancestorDepth  = blockNumber - number - 1
    if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH:
      return
    if number >= blockNumber:
      return
    c.host.getBlockHash(number)
  else:
    let
      blockNumber = c.vmState.blockNumber
      ancestorDepth = blockNumber - number - 1
    if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH:
      return
    if number >= blockNumber:
      return
    c.vmState.getAncestorHash(number.vmWordToBlockNumber)

template accountExists*(c: Computation, address: EthAddress): bool =
  when evmc_enabled:
    c.host.accountExists(address)
  else:
    if c.fork >= FkSpurious:
      not c.vmState.readOnlyStateDB.isDeadAccount(address)
    else:
      c.vmState.readOnlyStateDB.accountExists(address)

template getStorage*(c: Computation, slot: UInt256): UInt256 =
  when evmc_enabled:
    c.host.getStorage(c.msg.contractAddress, slot)
  else:
    c.vmState.readOnlyStateDB.getStorage(c.msg.contractAddress, slot)

template getBalance*(c: Computation, address: EthAddress): UInt256 =
  when evmc_enabled:
    c.host.getBalance(address)
  else:
    c.vmState.readOnlyStateDB.getBalance(address)

template getCodeSize*(c: Computation, address: EthAddress): uint =
  when evmc_enabled:
    c.host.getCodeSize(address)
  else:
    uint(c.vmState.readOnlyStateDB.getCodeSize(address))

template getCodeHash*(c: Computation, address: EthAddress): Hash256 =
  when evmc_enabled:
    c.host.getCodeHash(address)
  else:
    let
      db = c.vmState.readOnlyStateDB
    if not db.accountExists(address) or db.isEmptyAccount(address):
      default(Hash256)
    else:
      db.getCodeHash(address)

template selfDestruct*(c: Computation, address: EthAddress) =
  when evmc_enabled:
    c.host.selfDestruct(c.msg.contractAddress, address)
  else:
    c.execSelfDestruct(address)

template getCode*(c: Computation, address: EthAddress): seq[byte] =
  when evmc_enabled:
    c.host.copyCode(address)
  else:
    c.vmState.readOnlyStateDB.getCode(address)

template setTransientStorage*(c: Computation, slot, val: UInt256) =
  when evmc_enabled:
    c.host.setTransientStorage(c.msg.contractAddress, slot, val)
  else:
    c.vmState.stateDB.
      setTransientStorage(c.msg.contractAddress, slot, val)

template getTransientStorage*(c: Computation, slot: UInt256): UInt256 =
  when evmc_enabled:
    c.host.getTransientStorage(c.msg.contractAddress, slot)
  else:
    c.vmState.readOnlyStateDB.
      getTransientStorage(c.msg.contractAddress, slot)

proc newComputation*(vmState: BaseVMState, sysCall: bool, message: Message,
                     salt: ContractSalt = ZERO_CONTRACTSALT): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)
  result.sysCall = sysCall

  if result.msg.isCreate():
    result.msg.contractAddress = result.generateContractAddress(salt)
    result.code = newCodeStream(message.data)
    message.data = @[]
  else:
    result.code = newCodeStream(
      vmState.readOnlyStateDB.getCode(message.codeAddress))

proc newComputation*(vmState: BaseVMState, sysCall: bool,
                     message: Message, code: seq[byte]): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)
  result.code = newCodeStream(code)
  result.sysCall = sysCall

template gasCosts*(c: Computation): untyped =
  c.vmState.gasCosts

template fork*(c: Computation): untyped =
  c.vmState.fork

template isSuccess*(c: Computation): bool =
  c.error.isNil

template isError*(c: Computation): bool =
  not c.isSuccess

func shouldBurnGas*(c: Computation): bool =
  c.isError and c.error.burnsGas

proc snapshot*(c: Computation) =
  c.savePoint = c.vmState.stateDB.beginSavepoint()

proc commit*(c: Computation) =
  c.vmState.stateDB.commit(c.savePoint)

proc dispose*(c: Computation) =
  c.vmState.stateDB.safeDispose(c.savePoint)
  c.savePoint = nil

proc rollback*(c: Computation) =
  c.vmState.stateDB.rollback(c.savePoint)

proc setError*(c: Computation, msg: string, burnsGas = false) =
  c.error = Error(statusCode: EVMC_FAILURE, info: msg, burnsGas: burnsGas)

proc setError*(c: Computation, code: evmc_status_code, burnsGas = false) =
  c.error = Error(statusCode: code, info: $code, burnsGas: burnsGas)

proc setError*(c: Computation, code: evmc_status_code, msg: string, burnsGas = false) =
  c.error = Error(statusCode: code, info: msg, burnsGas: burnsGas)

func statusCode*(c: Computation): evmc_status_code =
  if c.isSuccess:
    EVMC_SUCCESS
  else:
    c.error.statusCode

func errorOpt*(c: Computation): Option[string] =
  if c.isSuccess:
    return none(string)
  if c.error.statusCode == EVMC_REVERT:
    return none(string)
  some(c.error.info)

proc writeContract*(c: Computation)
    {.gcsafe, raises: [CatchableError].} =
  template withExtra(tracer: untyped, args: varargs[untyped]) =
    tracer args, newContract=($c.msg.contractAddress),
      blockNumber=c.vmState.blockNumber,
      parentHash=($c.vmState.parent.blockHash)

  # In each check below, they are guarded by `len > 0`.  This includes writing
  # out the code, because the account already has zero-length code to handle
  # nested calls (this is specified).  May as well simplify other branches.
  let (len, fork) = (c.output.len, c.fork)
  if len == 0:
    return

  # EIP-3541 constraint (https://eips.ethereum.org/EIPS/eip-3541).
  if fork >= FkLondon and c.output[0] == 0xEF.byte:
    withExtra trace, "New contract code starts with 0xEF byte, not allowed by EIP-3541"
    c.setError(EVMC_CONTRACT_VALIDATION_FAILURE, true)
    return

  # EIP-170 constraint (https://eips.ethereum.org/EIPS/eip-3541).
  if fork >= FkSpurious and len > EIP170_MAX_CODE_SIZE:
    withExtra trace, "New contract code exceeds EIP-170 limit",
      codeSize=len, maxSize=EIP170_MAX_CODE_SIZE
    c.setError(EVMC_OUT_OF_GAS, true)
    return

  # Charge gas and write the code even if the code address is self-destructed.
  # Non-empty code in a newly created, self-destructed account is possible if
  # the init code calls `DELEGATECALL` or `CALLCODE` to other code which uses
  # `SELFDESTRUCT`.  This shows on Mainnet blocks 6001128..6001204, where the
  # gas difference matters.  The new code can be called later in the
  # transaction too, before self-destruction wipes the account at the end.

  let gasParams = GasParams(kind: Create, cr_memLength: len)
  let codeCost = c.gasCosts[Create].c_handler(0.u256, gasParams).gasCost
  if codeCost <= c.gasMeter.gasRemaining:
    c.gasMeter.consumeGas(codeCost, reason = "Write new contract code")
    c.vmState.mutateStateDB:
      db.setCode(c.msg.contractAddress, c.output)
    withExtra trace, "Writing new contract code"
    return

  if fork >= FkHomestead:
    # EIP-2 (https://eips.ethereum.org/EIPS/eip-2).
    c.setError(EVMC_OUT_OF_GAS, true)
  else:
    # Before EIP-2, when out of gas for code storage, the account ends up with
    # zero-length code and no error.  No gas is charged.  Code cited in EIP-2:
    # https://github.com/ethereum/pyethereum/blob/d117c8f3fd93/ethereum/processblock.py#L304
    # https://github.com/ethereum/go-ethereum/blob/401354976bb4/core/vm/instructions.go#L586
    # The account already has zero-length code to handle nested calls.
    withExtra trace, "New contract given empty code by pre-Homestead rules"

template chainTo*(c: Computation, toChild: typeof(c.child), after: untyped) =
  c.child = toChild
  c.continuation = proc() =
    c.continuation = nil
    after

# Register an async operation to be performed before the continuation is called.
template asyncChainTo*(c: Computation, asyncOperation: Future[void], after: untyped) =
  c.pendingAsyncOperation = asyncOperation
  c.continuation = proc() =
    c.continuation = nil
    after

proc merge*(c, child: Computation) =
  c.gasMeter.refundGas(child.gasMeter.gasRefunded)

proc execSelfDestruct*(c: Computation, beneficiary: EthAddress)
    {.gcsafe, raises: [CatchableError].} =

  c.vmState.mutateStateDB:
    let localBalance = c.getBalance(c.msg.contractAddress)

    # Register the account to be deleted
    if c.fork >= FkCancun:
      # Zeroing contract balance except beneficiary
      # is the same address
      db.subBalance(c.msg.contractAddress, localBalance)

      # Transfer to beneficiary
      db.addBalance(beneficiary, localBalance)

      db.selfDestruct6780(c.msg.contractAddress)
    else:
      # Transfer to beneficiary
      db.addBalance(beneficiary, localBalance)
      db.selfDestruct(c.msg.contractAddress)

    trace "SELFDESTRUCT",
      contractAddress = c.msg.contractAddress.toHex,
      localBalance = localBalance.toString,
      beneficiary = beneficiary.toHex

proc addLogEntry*(c: Computation, log: Log) =
  c.vmState.stateDB.addLogEntry(log)

proc getGasRefund*(c: Computation): GasInt =
  if c.isSuccess:
    result = c.gasMeter.gasRefunded

proc refundSelfDestruct*(c: Computation) =
  let cost = gasFees[c.fork][RefundSelfDestruct]
  let num  = c.vmState.stateDB.selfDestructLen
  c.gasMeter.refundGas(cost * num)

proc tracingEnabled*(c: Computation): bool =
  c.vmState.tracingEnabled

proc traceOpCodeStarted*(c: Computation, op: Op): int {.gcsafe, raises: [].} =
  c.vmState.captureOpStart(
    c,
    c.code.pc - 1,
    op,
    c.gasMeter.gasRemaining,
    c.msg.depth + 1)

proc traceOpCodeEnded*(c: Computation, op: Op, opIndex: int) {.gcsafe, raises: [].} =
  c.vmState.captureOpEnd(
    c,
    c.code.pc - 1,
    op,
    c.gasMeter.gasRemaining,
    c.gasMeter.gasRefunded,
    c.returnData,
    c.msg.depth + 1,
    opIndex)

proc traceError*(c: Computation) {.gcsafe, raises: [].} =
  c.vmState.captureFault(
    c,
    c.code.pc - 1,
    c.instr,
    c.gasMeter.gasRemaining,
    c.gasMeter.gasRefunded,
    c.returnData,
    c.msg.depth + 1,
    c.errorOpt)

proc prepareTracer*(c: Computation) =
  c.vmState.capturePrepare(c, c.msg.depth)

proc opcodeGastCost*(c: Computation, op: Op, gasCost: GasInt, reason: string) {.gcsafe, raises: [OutOfGas, ValueError].}  =
  c.vmState.captureGasCost(
    c,
    op,
    gasCost,
    c.gasMeter.gasRemaining,
    c.msg.depth + 1)
  c.gasMeter.consumeGas(gasCost, reason)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
