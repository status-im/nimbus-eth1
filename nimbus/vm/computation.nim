# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, macros, options, times,
  sets, eth/[common, keys],
  ../constants, ../errors, ../forks,
  ./interpreter/[opcode_values, gas_meter, gas_costs],
  ./code_stream, ./memory, ./message, ./stack, ./types, ./state,
  ../db/[accounts_cache, db_chain],
  ../utils/header, ./precompiles,
  ./transaction_tracer, ../utils

when defined(chronicles_log_level):
  import stew/byteutils

when defined(evmc_enabled):
  import evmc/evmc, evmc_helpers, evmc_api, stew/ranges/ptr_arith

logScope:
  topics = "vm computation"

const
  evmc_enabled* = defined(evmc_enabled)

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

template getBlockNumber*(c: Computation): Uint256 =
  when evmc_enabled:
    c.host.getTxContext().block_number.u256
  else:
    c.vmState.blockNumber.blockNumberToVmWord

template getDifficulty*(c: Computation): DifficultyInt =
  when evmc_enabled:
    Uint256.fromEvmc c.host.getTxContext().block_difficulty
  else:
    c.vmState.difficulty

template getGasLimit*(c: Computation): GasInt =
  when evmc_enabled:
    c.host.getTxContext().block_gas_limit.GasInt
  else:
    c.vmState.gasLimit

template getBaseFee*(c: Computation): Uint256 =
  when evmc_enabled:
    Uint256.fromEvmc c.host.getTxContext().block_base_fee
  else:
    c.vmState.baseFee

template getChainId*(c: Computation): uint =
  when evmc_enabled:
    Uint256.fromEvmc(c.host.getTxContext().chain_id).truncate(uint)
  else:
    c.vmState.chaindb.config.chainId.uint

template getOrigin*(c: Computation): EthAddress =
  when evmc_enabled:
    c.host.getTxContext().tx_origin
  else:
    c.vmState.txOrigin

template getGasPrice*(c: Computation): GasInt =
  when evmc_enabled:
    Uint256.fromEvmc(c.host.getTxContext().tx_gas_price).truncate(GasInt)
  else:
    c.vmState.txGasPrice

template getBlockHash*(c: Computation, blockNumber: Uint256): Hash256 =
  when evmc_enabled:
    c.host.getBlockHash(blockNumber)
  else:
    c.vmState.getAncestorHash(blockNumber.vmWordToBlockNumber)

template accountExists*(c: Computation, address: EthAddress): bool =
  when evmc_enabled:
    c.host.accountExists(address)
  else:
    if c.fork >= FkSpurious:
      not c.vmState.readOnlyStateDB.isDeadAccount(address)
    else:
      c.vmState.readOnlyStateDB.accountExists(address)

template getStorage*(c: Computation, slot: Uint256): Uint256 =
  when evmc_enabled:
    c.host.getStorage(c.msg.contractAddress, slot)
  else:
    c.vmState.readOnlyStateDB.getStorage(c.msg.contractAddress, slot)

template getBalance*(c: Computation, address: EthAddress): Uint256 =
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
    let db = c.vmState.readOnlyStateDB
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

proc generateContractAddress(c: Computation, salt: ContractSalt): EthAddress =
  if c.msg.kind == evmcCreate:
    let creationNonce = c.vmState.readOnlyStateDb().getNonce(c.msg.sender)
    result = generateAddress(c.msg.sender, creationNonce)
  else:
    result = generateSafeAddress(c.msg.sender, salt, c.msg.data)

import stew/byteutils

proc newComputation*(vmState: BaseVMState, message: Message,
                     salt: ContractSalt = ZERO_CONTRACTSALT): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)
  result.touchedAccounts = initHashSet[EthAddress]()
  result.selfDestructs = initHashSet[EthAddress]()

  if result.msg.isCreate():
    result.msg.contractAddress = result.generateContractAddress(salt)
    result.code = newCodeStream(message.data)
    message.data = @[]
  else:
    result.code = newCodeStream(vmState.readOnlyStateDb.getCode(message.codeAddress))

  when evmc_enabled:
    result.host.init(
      nim_host_get_interface(),
      cast[evmc_host_context](result)
    )

proc newComputation*(vmState: BaseVMState, message: Message, code: seq[byte]): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)
  result.touchedAccounts = initHashSet[EthAddress]()
  result.selfDestructs = initHashSet[EthAddress]()
  result.code = newCodeStream(code)

  when evmc_enabled:
    result.host.init(
      nim_host_get_interface(),
      cast[evmc_host_context](result)
    )

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

proc isSelfDestructed*(c: Computation, address: EthAddress): bool =
  result = address in c.selfDestructs

proc snapshot*(c: Computation) =
  c.savePoint = c.vmState.stateDB.beginSavePoint()

proc commit*(c: Computation) =
  c.vmState.stateDB.commit(c.savePoint)

proc dispose*(c: Computation) {.inline.} =
  c.vmState.stateDB.safeDispose(c.savePoint)
  c.savePoint = nil

proc rollback*(c: Computation) =
  c.vmState.stateDB.rollback(c.savePoint)

proc setError*(c: Computation, msg: string, burnsGas = false) {.inline.} =
  c.error = Error(info: msg, burnsGas: burnsGas)

proc writeContract*(c: Computation) =
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
    c.vmState.mutateStateDb:
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

proc initAddress(x: int): EthAddress {.compileTime.} = result[19] = x.byte
const ripemdAddr = initAddress(3)
proc executeOpcodes*(c: Computation) {.gcsafe.}

proc beforeExecCall(c: Computation) =
  c.snapshot()
  if c.msg.kind == evmcCall:
    c.vmState.mutateStateDb:
      db.subBalance(c.msg.sender, c.msg.value)
      db.addBalance(c.msg.contractAddress, c.msg.value)

proc afterExecCall(c: Computation) =
  ## Collect all of the accounts that *may* need to be deleted based on EIP161
  ## https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  ## also see: https://github.com/ethereum/EIPs/issues/716

  if c.isError or c.fork >= FKByzantium:
    if c.msg.contractAddress == ripemdAddr:
      # Special case to account for geth+parity bug
      c.vmState.touchedAccounts.incl c.msg.contractAddress

  if c.isSuccess:
    c.commit()
    c.touchedAccounts.incl c.msg.contractAddress
  else:
    c.rollback()

proc beforeExecCreate(c: Computation): bool =
  c.vmState.mutateStateDB:
    let nonce = db.getNonce(c.msg.sender)
    if nonce+1 < nonce:
      c.setError(&"Nonce overflow when sender={c.msg.sender.toHex} wants to create contract", false)
      return true
    db.setNonce(c.msg.sender, nonce+1)

    # We add this to the access list _before_ taking a snapshot.
    # Even if the creation fails, the access-list change should not be rolled back
    # EIP2929
    if c.fork >= FkBerlin:
      db.accessList(c.msg.contractAddress)

  c.snapshot()

  if c.vmState.readOnlyStateDb().hasCodeOrNonce(c.msg.contractAddress):
    c.setError(&"Address collision when creating contract address={c.msg.contractAddress.toHex}", true)
    c.rollback()
    return true

  c.vmState.mutateStateDb:
    db.subBalance(c.msg.sender, c.msg.value)
    db.addBalance(c.msg.contractAddress, c.msg.value)
    db.clearStorage(c.msg.contractAddress)
    if c.fork >= FkSpurious:
      # EIP161 nonce incrementation
      db.incNonce(c.msg.contractAddress)

  return false

proc afterExecCreate(c: Computation) =
  if c.isSuccess:
    # This can change `c.isSuccess`.
    c.writeContract()
    # Contract code should never be returned to the caller.  Only data from
    # `REVERT` is returned after a create.  Clearing in this branch covers the
    # right cases, particularly important with EVMC where it must be cleared.
    if c.output.len > 0:
      c.output = @[]

  if c.isSuccess:
    c.commit()
  else:
    c.rollback()

proc beforeExec(c: Computation): bool {.noinline.} =
  if not c.msg.isCreate:
    c.beforeExecCall()
    false
  else:
    c.beforeExecCreate()

proc afterExec(c: Computation) {.noinline.} =
  if not c.msg.isCreate:
    c.afterExecCall()
  else:
    c.afterExecCreate()

template chainTo*(c: Computation, toChild: typeof(c.child), after: untyped) =
  c.child = toChild
  c.continuation = proc() =
    c.continuation = nil
    after

when vm_use_recursion:
  # Recursion with tiny stack frame per level.
  proc execCallOrCreate*(c: Computation) =
    defer: c.dispose()
    if c.beforeExec():
      return
    c.executeOpcodes()
    while not c.continuation.isNil:
      when evmc_enabled:
        c.res = c.host.call(c.child[])
      else:
        execCallOrCreate(c.child)
      c.child = nil
      c.executeOpcodes()
    c.afterExec()

else:
  # No actual recursion, but simulate recursion including before/after/dispose.
  proc execCallOrCreate*(cParam: Computation) =
    var (c, before) = (cParam, true)
    defer:
      while not c.isNil:
        c.dispose()
        c = c.parent
    while true:
      while true:
        if before and c.beforeExec():
          break
        c.executeOpcodes()
        if c.continuation.isNil:
          c.afterExec()
          break
        (before, c.child, c, c.parent) = (true, nil.Computation, c.child, c)
      if c.parent.isNil:
        break
      c.dispose()
      (before, c.parent, c) = (false, nil.Computation, c.parent)

proc merge*(c, child: Computation) =
  c.logEntries.add child.logEntries
  c.gasMeter.refundGas(child.gasMeter.gasRefunded)
  c.selfDestructs.incl child.selfDestructs
  c.touchedAccounts.incl child.touchedAccounts

proc execSelfDestruct*(c: Computation, beneficiary: EthAddress) =
  c.vmState.mutateStateDB:
    let
      localBalance = c.getBalance(c.msg.contractAddress)
      beneficiaryBalance = c.getBalance(beneficiary)

    # Transfer to beneficiary
    db.setBalance(beneficiary, localBalance + beneficiaryBalance)

    # Zero the balance of the address being deleted.
    # This must come after sending to beneficiary in case the
    # contract named itself as the beneficiary.
    db.setBalance(c.msg.contractAddress, 0.u256)

    trace "SELFDESTRUCT",
      contractAddress = c.msg.contractAddress.toHex,
      localBalance = localBalance.toString,
      beneficiary = beneficiary.toHex

  c.touchedAccounts.incl beneficiary
  # Register the account to be deleted
  c.selfDestructs.incl(c.msg.contractAddress)

proc addLogEntry*(c: Computation, log: Log) {.inline.} =
  c.logEntries.add(log)

proc getGasRefund*(c: Computation): GasInt =
  if c.isSuccess:
    result = c.gasMeter.gasRefunded

proc refundSelfDestruct*(c: Computation) =
  let cost = gasFees[c.fork][RefundSelfDestruct]
  c.gasMeter.refundGas(cost * c.selfDestructs.len)

proc tracingEnabled*(c: Computation): bool {.inline.} =
  EnableTracing in c.vmState.tracer.flags

proc traceOpCodeStarted*(c: Computation, op: Op): int {.inline.} =
  c.vmState.tracer.traceOpCodeStarted(c, op)

proc traceOpCodeEnded*(c: Computation, op: Op, lastIndex: int) {.inline.} =
  c.vmState.tracer.traceOpCodeEnded(c, op, lastIndex)

proc traceError*(c: Computation) {.inline.} =
  c.vmState.tracer.traceError(c)

proc prepareTracer*(c: Computation) {.inline.} =
  c.vmState.tracer.prepare(c.msg.depth)

include interpreter_dispatch

when defined(evmc_enabled):
  include evmc_host
