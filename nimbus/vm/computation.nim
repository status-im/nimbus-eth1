# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, macros, terminal, math, tables,
  eth_common,
  ../constants, ../errors, ../validation, ../vm_state, ../vm_types,
  ./interpreter/[opcode_values, gas_meter, gas_costs, vm_forks],
  ./code_stream, ./memory, ./message, ./stack, ../db/[state_db, db_chain],
  ../utils/header, byteutils, ranges

logScope:
  topics = "vm computation"

proc newBaseComputation*(vmState: BaseVMState, blockNumber: UInt256, message: Message): BaseComputation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter.init(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[EthAddress, EthAddress]()
  result.logEntries = @[]
  result.code = newCodeStream(message.code)
  # result.rawOutput = "0x"
  result.gasCosts = blockNumber.toFork.forkToSchedule

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
    c.msg.origin,
    to,
    value,
    data,
    code,
    childOptions)

proc applyMessage(computation: var BaseComputation) =
  # TODO: Snapshots/Journaling, see: https://github.com/status-im/nimbus/issues/142
  #let snapshot = computation.vmState.snapshot()

  if computation.msg.depth > STACK_DEPTH_LIMIT:
      raise newException(StackDepthError, "Stack depth limit reached")

  if computation.msg.value != 0:
    let senderBalance =
      computation.vmState.chainDb.getStateDb(
        computation.vmState.blockHeader.hash, false).
        getBalance(computation.msg.sender)

    if sender_balance < computation.msg.value:
      raise newException(InsufficientFunds, 
          &"Insufficient funds: {senderBalance} < {computation.msg.value}"
      )

    computation.vmState.mutateStateDb:
      db.deltaBalance(computation.msg.sender, -1 * computation.msg.value)
      db.deltaBalance(computation.msg.storage_address, computation.msg.value)

    debug "Apply message",
      value = computation.msg.value,
      sender = computation.msg.sender.toHex,
      address = computation.msg.storage_address.toHex

  computation.opcodeExec(computation)

  # TODO: Snapshots/Journaling
  #[
  if result.isError:
      computation.vmState.revert(snapshot)
  else:
      computation.vmState.commit(snapshot)
  ]#

proc applyCreateMessage(fork: Fork, computation: var BaseComputation) =
  computation.applyMessage()
  if fork >= FkFrontier:
    # TODO: Take snapshot
    discard

  if computation.isError:
    if fork == FkSpurious:
      # TODO: Revert snapshot
      discard
    return
  else:
    let contractCode = computation.output
    if contractCode.len > 0:
      if fork >= FkSpurious and contractCode.len >= EIP170_CODE_SIZE_LIMIT:
        # TODO: Revert snapshot
        raise newException(OutOfGas, &"Contract code size exceeds EIP170 limit of {EIP170_CODE_SIZE_LIMIT}.  Got code of size: {contractCode.len}")

      try:
        computation.gasMeter.consumeGas(
          computation.gasCosts[Create].m_handler(0, 0, contractCode.len),
          reason = "Write contract code for CREATE")
      except OutOfGas:
        if fork == FkFrontier:
          computation.output = @[]
        else:
          # Different from Frontier:
          # Reverts state on gas failure while writing contract code.
          # TODO: Revert snapshot
          discard
    else:
      let storageAddr = computation.msg.storage_address
      debug "SETTING CODE",
        address = storageAddr.toHex,
        length = len(contract_code),
        hash = contractCode.rlpHash
      computation.vmState.mutateStateDB:
        db.setCode(storageAddr, contractCode.toRange)

proc generateChildComputation*(fork: Fork, computation: BaseComputation, childMsg: Message): BaseComputation =
  var childComp = newBaseComputation(
      computation.vmState,
      computation.vmState.blockHeader.blockNumber,
      childMsg)
  if childMsg.isCreate:
    fork.applyCreateMessage(childComp)
  else:
    applyMessage(childComp)
  return childComp

proc addChildComputation(fork: Fork, computation: BaseComputation, child: BaseComputation) =
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
  computation.children.add(child)

proc applyChildComputation*(computation: BaseComputation, childMsg: Message): BaseComputation =
  ## Apply the vm message childMsg as a child computation.
  let fork = computation.vmState.blockHeader.blockNumber.toFork
  result = fork.generateChildComputation(computation, childMsg)
  fork.addChildComputation(computation, result)

proc registerAccountForDeletion*(c: var BaseComputation, beneficiary: EthAddress) =
  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary

proc addLogEntry*(c: var BaseComputation, account: EthAddress, topics: seq[UInt256], data: seq[byte]) =
  c.logEntries.add((account, topics, data))

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

proc getLogEntries*(c: BaseComputation): seq[(string, seq[UInt256], string)] =
  # TODO
  if c.isError:
    result = @[]
  else:
    result = @[]

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
