# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, macros, terminal, math, tables, options,
  eth/[common, keys],
  ../constants, ../errors, ../validation, ../vm_state, ../vm_types,
  ./interpreter/[opcode_values, gas_meter, gas_costs, vm_forks],
  ./code_stream, ./memory, ./message, ./stack, ../db/[state_db, db_chain],
  ../utils/header, byteutils, ranges, precompiles,
  transaction_tracer

logScope:
  topics = "vm computation"

proc newBaseComputation*(vmState: BaseVMState, blockNumber: UInt256, message: Message, forkOverride=none(Fork)): BaseComputation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter.init(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[EthAddress, EthAddress]()
  result.code = newCodeStream(message.code)
  # result.rawOutput = "0x"
  result.gasCosts =
    if forkOverride.isSome:
      forkOverride.get.forkToSchedule
    else:
      blockNumber.toFork.forkToSchedule
  result.forkOverride = forkOverride

proc isOriginComputation*(c: BaseComputation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.isOrigin

template isSuccess*(c: BaseComputation): bool =
  c.error.isNil

template isError*(c: BaseComputation): bool =
  not c.isSuccess

func shouldBurnGas*(c: BaseComputation): bool =
  c.isError and c.error.burnsGas

func shouldEraseReturnData*(c: BaseComputation): bool =
  c.isError and c.error.erasesReturnData

func bytesToHex(x: openarray[byte]): string {.inline.} =
  ## TODO: use seq[byte] for raw data and delete this proc
  foldl(x, a & b.int.toHex(2).toLowerAscii, "0x")

func output*(c: BaseComputation): seq[byte] =
  if c.shouldEraseReturnData:
    @[]
  else:
    c.rawOutput

func `output=`*(c: var BaseComputation, value: openarray[byte]) =
  c.rawOutput = @value

proc outputHex*(c: BaseComputation): string =
  if c.shouldEraseReturnData:
    return "0x"
  c.rawOutput.bytesToHex

proc prepareChildMessage*(
    c: var BaseComputation,
    gas: GasInt,
    to: EthAddress,
    value: UInt256,
    data: seq[byte],
    code: seq[byte],
    options: MessageOptions = newMessageOptions()): Message =

  var childOptions = options
  childOptions.depth = c.msg.depth + 1
  result = newMessage(
    gas,
    c.msg.gasPrice,
    to,
    c.msg.origin,
    value,
    data,
    code,
    childOptions)

type
  ComputationSnapshot* = object
    snapshot: Snapshot
    computation: BaseComputation

proc snapshot*(computation: BaseComputation): ComputationSnapshot =
  result.snapshot = computation.vmState.snapshot()
  result.computation = computation

proc revert*(snapshot: var ComputationSnapshot, burnsGas: bool = false) =
  snapshot.snapshot.revert()
  snapshot.computation.error = Error(info: getCurrentExceptionMsg(), burnsGas: burnsGas)

proc commit*(snapshot: var ComputationSnapshot) {.inline.} =
  snapshot.snapshot.commit()

proc dispose*(snapshot: var ComputationSnapshot) {.inline.} =
  snapshot.snapshot.dispose()

proc applyMessageAux(computation: var BaseComputation, opCode: static[Op]) =
  if computation.msg.depth >= MaxCallDepth:
    raise newException(StackDepthError, "Stack depth limit reached")

  if computation.msg.value != 0:
    let senderBalance =
      computation.vmState.readOnlyStateDb().
        getBalance(computation.msg.sender)

    if senderBalance < computation.msg.value:
      raise newException(InsufficientFunds,
          &"Insufficient funds: {senderBalance} < {computation.msg.value}"
      )

    computation.vmState.mutateStateDb:
      db.subBalance(computation.msg.sender, computation.msg.value)
      db.addBalance(computation.msg.storageAddress, computation.msg.value)

  else:
    # even though the value is zero, the account
    # should be exist.
    computation.vmState.mutateStateDb:
      db.addBalance(computation.msg.storageAddress, computation.msg.value)

proc applyMessage(computation: var BaseComputation, opCode: static[Op]): bool =
  var snapshot = computation.snapshot()
  defer: snapshot.dispose()

  when opCode in {Call, Create}:
    try:
      computation.applyMessageAux(opCode)
    except VMError:
      snapshot.revert()
      debug "applyMessageAux failed", msg = computation.error.info
      return

  if computation.gasMeter.gasRemaining < 0:
    snapshot.commit()
    return

  try:
    # Run code
    # We cannot use the normal dispatching function `executeOpcodes`
    # within `interpreter_dispatch.nim` due to a cyclic dependency.
    computation.opcodeExec(computation)
    snapshot.commit()
  except VMError:
    snapshot.revert(true)
    debug "VMError applyMessage failed",
      msg = computation.error.info,
      depth = computation.msg.depth
  except EVMError:
    snapshot.revert() # TODO: true or false?
    debug "EVMError applyMessage failed",
      msg = computation.error.info,
      depth = computation.msg.depth

  result = not computation.isError

proc writeContract(fork: Fork, computation: var BaseComputation, opCode: static[Op]): bool =
  result = true

  let contractCode = computation.output
  if contractCode.len == 0: return

  if fork >= FkSpurious and contractCode.len >= EIP170_CODE_SIZE_LIMIT:
    debug "Contract code size exceeds EIP170", limit=EIP170_CODE_SIZE_LIMIT, actual=contractCode.len
    return false

  let storageAddr = computation.msg.storageAddress
  if computation.isSuicided(storageAddr): return

  # tricky gasCost: 1,0,0 -> createCost. 0,0,x -> depositCost
  let codeCost = computation.gasCosts[Create].m_handler(0, 0, contractCode.len)
  if computation.gasMeter.gasRemaining >= codeCost:
    computation.gasMeter.consumeGas(codeCost, reason = "Write contract code for CREATE")
    computation.vmState.mutateStateDb:
      db.setCode(storageAddr, contractCode.toRange)
    result = true
  else:
    if fork < FkHomestead: computation.output = @[]
    result = false

proc generateChildComputation*(fork: Fork, computation: var BaseComputation, childMsg: Message, opCode: static[Op]): BaseComputation =
  var childComp = newBaseComputation(
      computation.vmState,
      computation.vmState.blockNumber,
      childMsg,
      some(fork))

  # Copy the fork op code executor proc (assumes child computation is in the same fork)
  childComp.opCodeExec = computation.opCodeExec

  var snapshot = computation.snapshot()
  defer: snapshot.dispose()
  var contractOK = true

  if applyMessage(childComp, opCode):
    if childMsg.isCreate:
      contractOK = fork.writeContract(childComp, opCode)

  if not contractOK and fork == FkHomestead:
    # consume all gas
    snapshot.revert(true)
  else:
    snapshot.commit()

  return childComp

proc addChildComputation(fork: Fork, computation: var BaseComputation, child: BaseComputation) =
  if child.isError:
    if child.msg.isCreate:
      computation.returnData = child.output
    elif child.shouldBurnGas:
      computation.returnData = @[]
    else:
      computation.returnData = child.output
  else:
    if child.msg.isCreate:
      computation.returnData = @[]
    else:
      computation.returnData = child.output
    for k, v in child.accountsToDelete:
      computation.accountsToDelete[k] = v
    computation.logEntries.add child.logEntries
  computation.children.add(child)

proc getFork*(computation: BaseComputation): Fork =
  result =
    if computation.forkOverride.isSome:
      computation.forkOverride.get
    else:
      computation.vmState.blockNumber.toFork

proc applyChildComputation*(computation: var BaseComputation, childMsg: Message, opCode: static[Op]): BaseComputation =
  ## Apply the vm message childMsg as a child computation.
  let fork = computation.getFork
  result = fork.generateChildComputation(computation, childMsg, opCode)
  fork.addChildComputation(computation, result)

proc registerAccountForDeletion*(c: var BaseComputation, beneficiary: EthAddress) =
  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary

proc isSuicided*(c: var BaseComputation, address: EthAddress): bool =
  result = address in c.accountsToDelete

proc addLogEntry*(c: var BaseComputation, log: Log) {.inline.} =
  c.logEntries.add(log)

# many methods are basically TODO, but they still return valid values
# in order to test some existing code
func getAccountsForDeletion*(c: BaseComputation): seq[EthAddress] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]
    for account in c.accountsToDelete.keys:
      result.add(account)

proc getGasRefund*(c: BaseComputation): GasInt =
  if c.isError:
    result = 0
  else:
    result = c.gasMeter.gasRefunded + c.children.mapIt(it.getGasRefund()).foldl(a + b, 0'i64)

proc getGasUsed*(c: BaseComputation): GasInt =
  if c.shouldBurnGas:
    result = c.msg.gas
  else:
    result = max(0, c.msg.gas - c.gasMeter.gasRemaining)

proc getGasRemaining*(c: BaseComputation): GasInt =
  if c.shouldBurnGas:
    result = 0
  else:
    result = c.gasMeter.gasRemaining

proc tracingEnabled*(c: BaseComputation): bool =
  c.vmState.tracingEnabled

proc traceOpCodeStarted*(c: BaseComputation, op: Op): int =
  c.vmState.tracer.traceOpCodeStarted(c, op)

proc traceOpCodeEnded*(c: BaseComputation, op: Op, lastIndex: int) =
  c.vmState.tracer.traceOpCodeEnded(c, op, lastIndex)

proc traceError*(c: BaseComputation) =
  c.vmState.tracer.traceError(c)

proc prepareTracer*(c: BaseComputation) =
  c.vmState.tracer.prepare(c.msg.depth)
