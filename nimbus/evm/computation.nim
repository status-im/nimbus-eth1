# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  ".."/[db/accounts_cache, constants],
  "."/[code_stream, memory, message, stack, state],
  "."/[transaction_tracer, types],
  ./interpreter/[gas_meter, gas_costs, op_codes],
  ../common/[common, evmforks],
  ../utils/utils,
  chronicles, chronos,
  eth/[keys],
  sets

export
  common

{.push raises: [].}

logScope:
  topics = "vm computation"

when defined(chronicles_log_level):
  import stew/byteutils

when defined(evmc_enabled):
  import
    evmc/evmc,
    evmc_helpers,
    evmc_api,
    stew/ranges/ptr_arith

  export
    evmc,
    evmc_helpers,
    evmc_api,
    ptr_arith

const
  evmc_enabled* = defined(evmc_enabled)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc generateContractAddress(c: Computation, salt: ContractSalt): EthAddress =
  if c.msg.kind == evmcCreate:
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

template getTimestamp*(c: Computation): int64 =
  when evmc_enabled:
    c.host.getTxContext().block_timestamp
  else:
    c.vmState.timestamp.toUnix

template getBlockNumber*(c: Computation): UInt256 =
  when evmc_enabled:
    c.host.getTxContext().block_number.u256
  else:
    c.vmState.blockNumber.blockNumberToVmWord

template getDifficulty*(c: Computation): DifficultyInt =
  when evmc_enabled:
    UInt256.fromEvmc c.host.getTxContext().block_prev_randao
  else:
    c.vmState.difficulty

template getGasLimit*(c: Computation): GasInt =
  when evmc_enabled:
    c.host.getTxContext().block_gas_limit.GasInt
  else:
    c.vmState.gasLimit

template getBaseFee*(c: Computation): UInt256 =
  when evmc_enabled:
    UInt256.fromEvmc c.host.getTxContext().block_base_fee
  else:
    c.vmState.baseFee

template getChainId*(c: Computation): uint =
  when evmc_enabled:
    UInt256.fromEvmc(c.host.getTxContext().chain_id).truncate(uint)
  else:
    c.vmState.com.chainId.uint

template getOrigin*(c: Computation): EthAddress =
  when evmc_enabled:
    c.host.getTxContext().tx_origin
  else:
    c.vmState.txOrigin

template getGasPrice*(c: Computation): GasInt =
  when evmc_enabled:
    UInt256.fromEvmc(c.host.getTxContext().tx_gas_price).truncate(GasInt)
  else:
    c.vmState.txGasPrice

template getVersionedHashes*(c: Computation): VersionedHashes =
  when evmc_enabled:
    # TODO: implement
    @[]
  else:
    c.vmState.txVersionedHashes

template getVersionedHashesLen*(c: Computation): int =
  when evmc_enabled:
    # TODO: implement
    0
  else:
    c.vmState.txVersionedHashes.len

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

proc newComputation*(vmState: BaseVMState, message: Message,
                     salt: ContractSalt = ZERO_CONTRACTSALT): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)

  if result.msg.isCreate():
    result.msg.contractAddress = result.generateContractAddress(salt)
    result.code = newCodeStream(message.data)
    message.data = @[]
  else:
    result.code = newCodeStream(
      vmState.readOnlyStateDB.getCode(message.codeAddress))

proc newComputation*(vmState: BaseVMState, message: Message, code: seq[byte]): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)
  result.code = newCodeStream(code)

template gasCosts*(c: Computation): untyped =
  c.vmState.gasCosts

template fork*(c: Computation): untyped =
  c.vmState.fork

proc isOriginComputation*(c: Computation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.sender == c.vmState.txOrigin

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
  c.error = Error(info: msg, burnsGas: burnsGas)

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
    # TODO: Return `EVMC_CONTRACT_VALIDATION_FAILURE` (like Silkworm).
    c.setError("EVMC_CONTRACT_VALIDATION_FAILURE", true)
    return

  # EIP-170 constraint (https://eips.ethereum.org/EIPS/eip-3541).
  if fork >= FkSpurious and len > EIP170_MAX_CODE_SIZE:
    withExtra trace, "New contract code exceeds EIP-170 limit",
      codeSize=len, maxSize=EIP170_MAX_CODE_SIZE
    # TODO: Return `EVMC_OUT_OF_GAS` (like Silkworm).
    c.setError("EVMC_OUT_OF_GAS", true)
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
    # TODO: Return `EVMC_OUT_OF_GAS` (like Silkworm).
    c.setError("EVMC_OUT_OF_GAS", true)
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

    # Transfer to beneficiary
    db.addBalance(beneficiary, localBalance)

    # Zero the balance of the address being deleted.
    # This must come after sending to beneficiary in case the
    # contract named itself as the beneficiary.
    db.setBalance(c.msg.contractAddress, 0.u256)

    # Register the account to be deleted
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
  TracerFlags.EnableTracing in c.vmState.tracer.flags

proc traceOpCodeStarted*(c: Computation, op: Op): int
    {.gcsafe, raises: [CatchableError].} =
  c.vmState.tracer.traceOpCodeStarted(c, op)

proc traceOpCodeEnded*(c: Computation, op: Op, lastIndex: int)
    {.gcsafe, raises: [CatchableError].} =
  c.vmState.tracer.traceOpCodeEnded(c, op, lastIndex)

proc traceError*(c: Computation)
    {.gcsafe, raises: [CatchableError].} =
  c.vmState.tracer.traceError(c)

proc prepareTracer*(c: Computation) =
  c.vmState.tracer.prepare(c.msg.depth)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
