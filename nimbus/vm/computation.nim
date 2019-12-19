# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, macros, math, tables, options,
  sets, eth/[common, keys], eth/trie/db as triedb,
  ../constants, ../errors, ../vm_state, ../vm_types,
  ./interpreter/[opcode_values, gas_meter, gas_costs, vm_forks],
  ./code_stream, ./memory, ./message, ./stack, ../db/[state_db, db_chain],
  ../utils/header, stew/[byteutils, ranges], precompiles,
  transaction_tracer, eth/trie/trie_defs

logScope:
  topics = "vm computation"

proc newBaseComputation*(vmState: BaseVMState, blockNumber: BlockNumber, message: Message, forkOverride=none(Fork)): BaseComputation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter.init(message.gas)
  result.children = @[]
  result.accountsToDelete = initTable[EthAddress, EthAddress]()
  result.suicides = initHashSet[EthAddress]()
  result.code = newCodeStream(message.code)
  # result.rawOutput = "0x"
  result.gasCosts =
    if forkOverride.isSome:
      forkOverride.get.forkToSchedule
    else:
      blockNumber.toFork.forkToSchedule
  result.forkOverride = forkOverride
  # a dummy/terminus continuation proc
  result.nextProc = proc() =
    discard

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

func `output=`*(c: BaseComputation, value: openarray[byte]) =
  c.rawOutput = @value

proc outputHex*(c: BaseComputation): string =
  if c.shouldEraseReturnData:
    return "0x"
  c.rawOutput.bytesToHex

proc isSuicided*(c: BaseComputation, address: EthAddress): bool =
  result = address in c.accountsToDelete

proc prepareChildMessage*(
    c: BaseComputation,
    gas: GasInt,
    to: EthAddress,
    value: UInt256,
    data: seq[byte],
    code: seq[byte],
    contractCreation: bool,
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
    contractCreation,
    childOptions)

proc snapshot*(comp: BaseComputation) =
  comp.dbsnapshot.transaction = comp.vmState.chaindb.db.beginTransaction()
  comp.dbsnapshot.intermediateRoot = comp.vmState.accountDb.rootHash
  comp.vmState.blockHeader.stateRoot = comp.vmState.accountDb.rootHash

proc commit*(comp: BaseComputation) =
  comp.dbsnapshot.transaction.commit()
  comp.vmState.accountDb.rootHash = comp.vmState.blockHeader.stateRoot

proc dispose*(comp: BaseComputation) {.inline.} =
  comp.dbsnapshot.transaction.dispose()

proc rollback*(comp: BaseComputation) =
  comp.dbsnapshot.transaction.rollback()
  comp.vmState.accountDb.rootHash = comp.dbsnapshot.intermediateRoot
  comp.vmState.blockHeader.stateRoot = comp.dbsnapshot.intermediateRoot

proc setError*(comp: BaseComputation, msg: string, burnsGas = false) {.inline.} =
  comp.error = Error(info: msg, burnsGas: burnsGas)

proc getFork*(computation: BaseComputation): Fork =
  result =
    if computation.forkOverride.isSome:
      computation.forkOverride.get
    else:
      computation.vmState.blockNumber.toFork

proc writeContract*(computation: BaseComputation, fork: Fork): bool {.gcsafe.} =
  result = true

  let contractCode = computation.output
  if contractCode.len == 0: return

  if fork >= FkSpurious and contractCode.len >= EIP170_CODE_SIZE_LIMIT:
    debug "Contract code size exceeds EIP170", limit=EIP170_CODE_SIZE_LIMIT, actual=contractCode.len
    return false

  let storageAddr = computation.msg.storageAddress
  if computation.isSuicided(storageAddr): return

  let gasParams = GasParams(kind: Create, cr_memLength: contractCode.len)
  let codeCost = computation.gasCosts[Create].c_handler(0.u256, gasParams).gasCost
  if computation.gasMeter.gasRemaining >= codeCost:
    computation.gasMeter.consumeGas(codeCost, reason = "Write contract code for CREATE")
    computation.vmState.mutateStateDb:
      db.setCode(storageAddr, contractCode.toRange)
    result = true
  else:
    if fork < FkHomestead or fork >= FkByzantium: computation.output = @[]
    result = false

proc transferBalance(computation: BaseComputation, opCode: static[Op]) =
  let senderBalance = computation.vmState.readOnlyStateDb().
                      getBalance(computation.msg.sender)

  if senderBalance < computation.msg.value:
    computation.setError(&"insufficient funds available={senderBalance}, needed={computation.msg.value}")
    return

  when opCode in {Call, Create}:
    computation.vmState.mutateStateDb:
      db.subBalance(computation.msg.sender, computation.msg.value)
      db.addBalance(computation.msg.storageAddress, computation.msg.value)

template continuation*(comp: BaseComputation, body: untyped) =
  # this is a helper template to implement continuation
  # passing and convert all recursion into tail call
  var tmpNext = comp.nextProc
  comp.nextProc = proc() {.gcsafe.} =
    body
    tmpNext()

proc postExecuteVM(computation: BaseComputation, opCode: static[Op]) {.gcsafe.} =
  when opCode == Create:
    if computation.isSuccess:
      let fork = computation.getFork
      let contractFailed = not computation.writeContract(fork)
      if contractFailed and fork >= FkHomestead:
        computation.setError(&"writeContract failed, depth={computation.msg.depth}", true)

  if computation.isSuccess:
    computation.commit()
  else:
    computation.rollback()

proc executeOpcodes*(computation: BaseComputation) {.gcsafe.}

proc applyMessage*(computation: BaseComputation, opCode: static[Op]) =
  if computation.msg.depth > MaxCallDepth:
    computation.setError(&"Stack depth limit reached depth={computation.msg.depth}")
    computation.nextProc()
    return

  computation.snapshot()
  defer:
    computation.dispose()

  # EIP161 nonce incrementation
  when opCode in {Create, Create2}:
    if computation.getFork >= FkSpurious:
      computation.vmState.mutateStateDb:
        db.incNonce(computation.msg.storageAddress)
        if computation.getFork >= FkByzantium:
          # RevertInCreateInInit.json
          db.setStorageRoot(computation.msg.storageAddress, emptyRlpHash)

  when opCode in {CallCode, Call, Create}:
    computation.transferBalance(opCode)
    if computation.isError():
      computation.rollback()
      computation.nextProc()
      return

  if computation.gasMeter.gasRemaining < 0:
    computation.commit()
    computation.nextProc()
    return

  continuation(computation):
    postExecuteVM(computation, opCode)

  executeOpcodes(computation)

proc addChildComputation*(computation: BaseComputation, child: BaseComputation) =
  if child.isError:
    if child.shouldBurnGas:
      computation.returnData = @[]
    else:
      computation.returnData = child.output
  else:
    if child.msg.isCreate:
      computation.returnData = @[]
    else:
      computation.returnData = child.output
    computation.logEntries.add child.logEntries
    computation.gasMeter.refundGas(child.gasMeter.gasRefunded)
    computation.suicides.incl child.suicides

  if not child.shouldBurnGas:
    computation.gasMeter.returnGas(child.gasMeter.gasRemaining)
  computation.children.add(child)

proc registerAccountForDeletion*(c: BaseComputation, beneficiary: EthAddress) =
  if c.msg.storageAddress in c.accountsToDelete:
    raise newException(ValueError,
      "invariant:  should be impossible for an account to be " &
      "registered for deletion multiple times")
  c.accountsToDelete[c.msg.storageAddress] = beneficiary
  c.suicides.incl(c.msg.storageAddress)

proc addLogEntry*(c: BaseComputation, log: Log) {.inline.} =
  c.logEntries.add(log)

iterator accountsForDeletion*(c: BaseComputation): EthAddress =
  if c.isSuccess:
    for address in c.suicides:
      yield address

proc getGasRefund*(c: BaseComputation): GasInt =
  if c.isSuccess:
    result = c.gasMeter.gasRefunded

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

proc collectTouchedAccounts*(c: BaseComputation, output: var HashSet[EthAddress], ancestorHadError: bool = false) =
  ## Collect all of the accounts that *may* need to be deleted based on EIP161:
  ## https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  ## also see: https://github.com/ethereum/EIPs/issues/716

  proc cmpThree(address: EthAddress): bool =
    # looking for RIPEMD160
    for i in 0..18:
      if address[i] != 0: return
    result = address[19] == byte(3)

  let isIstanbul = c.getFork >= FkIstanbul
  let condition = if isIstanbul: c.isError or ancestorHadError
                  else: c.isError and c.isOriginComputation

  for _, beneficiary in c.accountsToDelete:
    if condition:
      # Special case to account for geth+parity bug
      # https://github.com/ethereum/EIPs/issues/716
      if beneficiary.cmpThree:
        output.incl beneficiary
      continue
    else:
      output.incl beneficiary

  if not c.msg.isCreate:
    if condition:
      # Special case to account for geth+parity bug
      # https://github.com/ethereum/EIPs/issues/716
      if cmpThree(c.msg.storageAddress):
        output.incl c.msg.storageAddress
    else:
      output.incl c.msg.storageAddress

  if c.isSuccess or isIstanbul:
  # recurse into nested computations (even errored ones, since looking for RIPEMD160)
    for child in c.children:
      child.collectTouchedAccounts(output, c.isError or ancestorHadError)

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

include interpreter_dispatch
