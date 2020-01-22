# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, macros, math, options, times,
  sets, eth/[common, keys], eth/trie/db as triedb,
  ../constants, ../errors, ../vm_state, ../vm_types,
  ./interpreter/[opcode_values, gas_meter, gas_costs, vm_forks],
  ./code_stream, ./memory, ./message, ./stack, ../db/[state_db, db_chain],
  ../utils/header, stew/[byteutils, ranges], precompiles,
  transaction_tracer, ../utils

when defined(evmc_enabled):
  import evmc/evmc, evmc_helpers, evmc_api

logScope:
  topics = "vm computation"

const
  evmc_enabled* = defined(evmc_enabled)

template getCoinbase*(c: Computation): EthAddress =
  when evmc_enabled:
    fromEvmc c.host.getTxContext().block_coinbase
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

template getChainId*(c: Computation): uint =
  when evmc_enabled:
    Uint256.fromEvmc(c.host.getTxContext().chain_id).truncate(uint)
  else:
    c.vmState.chaindb.config.chainId

template getOrigin*(c: Computation): EthAddress =
  when evmc_enabled:
    fromEvmc c.host.getTxContext().tx_origin
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
    c.vmState.readOnlyStateDB.getStorage(c.msg.contractAddress, slot)[0]

template getBalance*(c: Computation, address: EthAddress): Uint256 =
  when evmc_enabled:
    c.host.getBalance(address)
  else:
    c.vmState.readOnlyStateDB.getBalance(address)

template getCodeSize*(c: Computation, address: EthAddress): uint =
  when evmc_enabled:
    c.host.getCodeSize(address)
  else:
    uint(c.vmState.readOnlyStateDB.getCode(address).len)

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

template getCode*(c: Computation, address: EthAddress): ByteRange =
  when evmc_enabled:
    c.host.copyCode(address).toRange
  else:
    c.vmState.readOnlyStateDB.getCode(address)

proc generateContractAddress(c: Computation, salt: Option[Uint256]): EthAddress =
  if c.msg.kind == evmcCreate:
    let creationNonce = c.vmState.readOnlyStateDb().getNonce(c.msg.sender)
    result = generateAddress(c.msg.sender, creationNonce)
  else:
    result = generateSafeAddress(c.msg.sender, salt.get(), c.msg.data)

proc newComputation*(vmState: BaseVMState, message: Message, salt=none(Uint256)): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter.init(message.gas)
  result.touchedAccounts = initHashSet[EthAddress]()
  result.suicides = initHashSet[EthAddress]()

  if result.msg.isCreate():
    result.msg.contractAddress = result.generateContractAddress(salt)
    result.code = newCodeStream(message.data)
    message.data = @[]
  else:
    result.code = newCodeStream(vmState.readOnlyStateDb.getCode(message.codeAddress).toSeq)

  when evmc_enabled:
    result.host.init(
      nim_host_get_interface(),
      cast[evmc_host_context](result)
    )

  # a dummy/terminus continuation proc
  result.nextProc = proc() =
    discard

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

func output*(c: Computation): seq[byte] =
  c.rawOutput

func `output=`*(c: Computation, value: openarray[byte]) =
  c.rawOutput = @value

proc isSuicided*(c: Computation, address: EthAddress): bool =
  result = address in c.suicides

proc snapshot*(c: Computation) =
  c.dbsnapshot.transaction = c.vmState.chaindb.db.beginTransaction()
  c.dbsnapshot.intermediateRoot = c.vmState.accountDb.rootHash

proc commit*(c: Computation) =
  c.dbsnapshot.transaction.commit()

proc dispose*(c: Computation) {.inline.} =
  c.dbsnapshot.transaction.dispose()

proc rollback*(c: Computation) =
  c.dbsnapshot.transaction.rollback()
  c.vmState.accountDb.rootHash = c.dbsnapshot.intermediateRoot

proc setError*(c: Computation, msg: string, burnsGas = false) {.inline.} =
  c.error = Error(info: msg, burnsGas: burnsGas)

proc writeContract*(c: Computation, fork: Fork): bool {.gcsafe.} =
  result = true

  let contractCode = c.output
  if contractCode.len == 0: return

  if fork >= FkSpurious and contractCode.len >= EIP170_CODE_SIZE_LIMIT:
    debug "Contract code size exceeds EIP170", limit=EIP170_CODE_SIZE_LIMIT, actual=contractCode.len
    return false

  let storageAddr = c.msg.contractAddress
  if c.isSuicided(storageAddr): return

  let gasParams = GasParams(kind: Create, cr_memLength: contractCode.len)
  let codeCost = c.gasCosts[Create].c_handler(0.u256, gasParams).gasCost
  if c.gasMeter.gasRemaining >= codeCost:
    c.gasMeter.consumeGas(codeCost, reason = "Write contract code for CREATE")
    c.vmState.mutateStateDb:
      db.setCode(storageAddr, contractCode.toRange)
    result = true
  else:
    if fork < FkHomestead or fork >= FkByzantium: c.output = @[]
    result = false

template continuation*(c: Computation, body: untyped) =
  # this is a helper template to implement continuation
  # passing and convert all recursion into tail call
  var tmpNext = c.nextProc
  c.nextProc = proc() {.gcsafe.} =
    body
    tmpNext()

proc initAddress(x: int): EthAddress {.compileTime.} = result[19] = x.byte
const ripemdAddr = initAddress(3)

proc postExecuteVM(c: Computation, opCode: static[Op]) {.gcsafe.} =
  when opCode == Create:
    if c.isSuccess:
      let fork = c.fork
      let contractFailed = not c.writeContract(fork)
      if contractFailed and fork >= FkHomestead:
        c.setError(&"writeContract failed, depth={c.msg.depth}", true)

  if c.isSuccess:
    c.commit()
  else:
    c.rollback()

proc executeOpcodes*(c: Computation) {.gcsafe.}

proc applyMessage*(c: Computation, opCode: static[Op]) =
  when opCode == Create:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)

  c.snapshot()
  defer:
    c.dispose()

  when opCode == Create:
    if c.vmState.readOnlyStateDb().hasCodeOrNonce(c.msg.contractAddress):
      c.setError("Address collision when creating contract address={c.msg.contractAddress.toHex}", true)
      c.rollback()
      c.nextProc()
      return

    c.vmState.mutateStateDb:
      db.clearStorage(c.msg.contractAddress)
      if c.fork >= FkSpurious:
        # EIP161 nonce incrementation
        db.incNonce(c.msg.contractAddress)

  when opCode in {Call, Create}:
    c.vmState.mutateStateDb:
      db.subBalance(c.msg.sender, c.msg.value)
      db.addBalance(c.msg.contractAddress, c.msg.value)

  if c.gasMeter.gasRemaining < 0:
    c.commit()
    c.nextProc()
    return

  continuation(c):
    postExecuteVM(c, opCode)

  executeOpcodes(c)

proc addChildComputation*(c, child: Computation) =
  if child.isError or c.fork == FKIstanbul:
    if not child.msg.isCreate:
      if child.msg.contractAddress == ripemdAddr:
        child.vmState.touchedAccounts.incl child.msg.contractAddress

  if child.isError:
    if child.shouldBurnGas:
      c.returnData = @[]
    else:
      c.returnData = child.output
  else:
    if child.msg.isCreate:
      c.returnData = @[]
    else:
      c.returnData = child.output
      child.touchedAccounts.incl child.msg.contractAddress
    c.logEntries.add child.logEntries
    c.gasMeter.refundGas(child.gasMeter.gasRefunded)
    c.suicides.incl child.suicides
    c.touchedAccounts.incl child.touchedAccounts

  if not child.shouldBurnGas:
    c.gasMeter.returnGas(child.gasMeter.gasRemaining)

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
  c.suicides.incl(c.msg.contractAddress)

proc addLogEntry*(c: Computation, log: Log) {.inline.} =
  c.logEntries.add(log)

proc getSuicides*(c: Computation): HashSet[EthAddress] =
  if c.isSuccess:
    result = c.suicides

proc getGasRefund*(c: Computation): GasInt =
  if c.isSuccess:
    result = c.gasMeter.gasRefunded

proc getGasUsed*(c: Computation): GasInt =
  if c.shouldBurnGas:
    result = c.msg.gas
  else:
    result = max(0, c.msg.gas - c.gasMeter.gasRemaining)

proc getGasRemaining*(c: Computation): GasInt =
  if c.shouldBurnGas:
    result = 0
  else:
    result = c.gasMeter.gasRemaining

proc refundSelfDestruct*(c: Computation) =
  let cost = gasFees[c.fork][RefundSelfDestruct]
  c.gasMeter.refundGas(cost * c.suicides.len)

proc collectTouchedAccounts*(c: Computation) =
  ## Collect all of the accounts that *may* need to be deleted based on EIP161:
  ## https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  ## also see: https://github.com/ethereum/EIPs/issues/716

  if c.isSuccess:
    if not c.msg.isCreate:
      c.touchedAccounts.incl c.msg.contractAddress
    c.vmState.touchedAccounts.incl c.touchedAccounts
  else:
    if not c.msg.isCreate:
      # Special case to account for geth+parity bug
      # https://github.com/ethereum/EIPs/issues/716
      if c.msg.contractAddress == ripemdAddr:
        c.vmState.touchedAccounts.incl c.msg.contractAddress

proc tracingEnabled*(c: Computation): bool =
  c.vmState.tracingEnabled

proc traceOpCodeStarted*(c: Computation, op: Op): int =
  c.vmState.tracer.traceOpCodeStarted(c, op)

proc traceOpCodeEnded*(c: Computation, op: Op, lastIndex: int) =
  c.vmState.tracer.traceOpCodeEnded(c, op, lastIndex)

proc traceError*(c: Computation) =
  c.vmState.tracer.traceError(c)

proc prepareTracer*(c: Computation) =
  c.vmState.tracer.prepare(c.msg.depth)

include interpreter_dispatch

when defined(evmc_enabled):
  include evmc_host
