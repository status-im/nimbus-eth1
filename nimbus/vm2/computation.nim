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
  ../constants,
  ../db/accounts_cache,
  ../utils,
  ./code_stream,
  ./interpreter/[forks_list, gas_meter, gas_costs, op_codes],
  ./memory,
  ./message,
  ./stack,
  ./state,
  ./transaction_tracer,
  ./types,
  chronicles,
  eth/[common, keys],
  options,
  sets

logScope:
  topics = "vm computation"

when defined(chronicles_log_level):
  import stew/byteutils

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc generateContractAddress(c: Computation, salt: Uint256): EthAddress =
  if c.msg.kind == evmcCreate:
    let creationNonce = c.vmState.readOnlyStateDb().getNonce(c.msg.sender)
    result = generateAddress(c.msg.sender, creationNonce)
  else:
    result = generateSafeAddress(c.msg.sender, salt, c.msg.data)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template getCoinbase*(c: Computation): EthAddress =
  c.vmState.coinbase

template getTimestamp*(c: Computation): int64 =
  c.vmState.timestamp.toUnix

template getBlockNumber*(c: Computation): Uint256 =
  c.vmState.blockNumber.blockNumberToVmWord

template getDifficulty*(c: Computation): DifficultyInt =
  c.vmState.difficulty

template getGasLimit*(c: Computation): GasInt =
  c.vmState.gasLimit

template getChainId*(c: Computation): uint =
  c.vmState.chaindb.config.chainId.uint

template getOrigin*(c: Computation): EthAddress =
  c.vmState.txOrigin

template getGasPrice*(c: Computation): GasInt =
  c.vmState.txGasPrice

template getBlockHash*(c: Computation, blockNumber: Uint256): Hash256 =
  c.vmState.getAncestorHash(blockNumber.vmWordToBlockNumber)

template accountExists*(c: Computation, address: EthAddress): bool =
  if c.fork >= FkSpurious:
    not c.vmState.readOnlyStateDB.isDeadAccount(address)
  else:
    c.vmState.readOnlyStateDB.accountExists(address)

template getStorage*(c: Computation, slot: Uint256): Uint256 =
  c.vmState.readOnlyStateDB.getStorage(c.msg.contractAddress, slot)

template getBalance*(c: Computation, address: EthAddress): Uint256 =
  c.vmState.readOnlyStateDB.getBalance(address)

template getCodeSize*(c: Computation, address: EthAddress): uint =
  uint(c.vmState.readOnlyStateDB.getCodeSize(address))

template getCodeHash*(c: Computation, address: EthAddress): Hash256 =
  let
    db = c.vmState.readOnlyStateDB
  if not db.accountExists(address) or db.isEmptyAccount(address):
    default(Hash256)
  else:
    db.getCodeHash(address)

template selfDestruct*(c: Computation, address: EthAddress) =
  c.execSelfDestruct(address)

template getCode*(c: Computation, address: EthAddress): seq[byte] =
  c.vmState.readOnlyStateDB.getCode(address)

proc newComputation*(vmState: BaseVMState,
                     message: Message, salt= 0.u256): Computation =
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
    result.code = newCodeStream(
      vmState.readOnlyStateDb.getCode(message.codeAddress))

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
  c.savePoint = c.vmState.accountDb.beginSavePoint()

proc commit*(c: Computation) =
  c.vmState.accountDb.commit(c.savePoint)

proc dispose*(c: Computation) {.inline.} =
  c.vmState.accountDb.safeDispose(c.savePoint)
  c.savePoint = nil

proc rollback*(c: Computation) =
  c.vmState.accountDb.rollback(c.savePoint)

proc setError*(c: Computation, msg: string, burnsGas = false) {.inline.} =
  c.error = Error(info: msg, burnsGas: burnsGas)

proc writeContract*(c: Computation, fork: Fork): bool {.gcsafe.} =
  result = true

  let contractCode = c.output
  if contractCode.len == 0: return

  if fork >= FkSpurious and contractCode.len >= EIP170_CODE_SIZE_LIMIT:
    debug "Contract code size exceeds EIP170",
      limit = EIP170_CODE_SIZE_LIMIT,
      actual = contractCode.len
    return false

  let storageAddr = c.msg.contractAddress
  if c.isSelfDestructed(storageAddr): return

  let gasParams = GasParams(kind: Create, cr_memLength: contractCode.len)
  let codeCost = c.gasCosts[Create].c_handler(0.u256, gasParams).gasCost
  if c.gasMeter.gasRemaining >= codeCost:
    c.gasMeter.consumeGas(codeCost, reason = "Write contract code for CREATE")
    c.vmState.mutateStateDb:
      db.setCode(storageAddr, contractCode)
    result = true
  else:
    if fork < FkHomestead or FkByzantium <= fork:
      c.output = @[]
    result = false

template chainTo*(c, toChild: Computation, after: untyped) =
  c.child = toChild
  c.continuation = proc() =
    after

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
  TracerFlags.EnableTracing in c.vmState.tracer.flags

proc traceOpCodeStarted*(c: Computation, op: Op): int {.inline.} =
  c.vmState.tracer.traceOpCodeStarted(c, op)

proc traceOpCodeEnded*(c: Computation, op: Op, lastIndex: int) {.inline.} =
  c.vmState.tracer.traceOpCodeEnded(c, op, lastIndex)

proc traceError*(c: Computation) {.inline.} =
  c.vmState.tracer.traceError(c)

proc prepareTracer*(c: Computation) {.inline.} =
  c.vmState.tracer.prepare(c.msg.depth)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
