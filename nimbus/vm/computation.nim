# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles, strformat, strutils, sequtils, macros, math, options,
  sets, eth/[common, keys], eth/trie/db as triedb,
  ../constants, ../errors, ../vm_state, ../vm_types,
  ./interpreter/[opcode_values, gas_meter, gas_costs, vm_forks],
  ./code_stream, ./memory, ./message, ./stack, ../db/[state_db, db_chain],
  ../utils/header, stew/[byteutils, ranges], precompiles,
  transaction_tracer, eth/trie/trie_defs

logScope:
  topics = "vm computation"

proc newComputation*(vmState: BaseVMState, message: Message, forkOverride=none(Fork)): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.gasMeter.init(message.gas)
  result.touchedAccounts = initHashSet[EthAddress]()
  result.suicides = initHashSet[EthAddress]()
  result.code = newCodeStream(message.code)
  result.fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.blockNumber.toFork
  result.gasCosts = result.fork.forkToSchedule
  # a dummy/terminus continuation proc
  result.nextProc = proc() =
    discard

proc isOriginComputation*(c: Computation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.isOrigin

template isSuccess*(c: Computation): bool =
  c.error.isNil

template isError*(c: Computation): bool =
  not c.isSuccess

func shouldBurnGas*(c: Computation): bool =
  c.isError and c.error.burnsGas

func bytesToHex(x: openarray[byte]): string {.inline.} =
  ## TODO: use seq[byte] for raw data and delete this proc
  foldl(x, a & b.int.toHex(2).toLowerAscii, "0x")

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

proc transferBalance(c: Computation, opCode: static[Op]) =
  let senderBalance = c.vmState.readOnlyStateDb().
                      getBalance(c.msg.sender)

  if senderBalance < c.msg.value:
    c.setError(&"insufficient funds available={senderBalance}, needed={c.msg.value}")
    return

  when opCode in {Call, Create}:
    c.vmState.mutateStateDb:
      db.subBalance(c.msg.sender, c.msg.value)
      db.addBalance(c.msg.contractAddress, c.msg.value)

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
  c.snapshot()
  defer:
    c.dispose()

  # EIP161 nonce incrementation
  when opCode in {Create, Create2}:
    if c.fork >= FkSpurious:
      c.vmState.mutateStateDb:
        db.incNonce(c.msg.contractAddress)
        if c.fork >= FkByzantium:
          # RevertInCreateInInit.json
          db.setStorageRoot(c.msg.contractAddress, emptyRlpHash)

  when opCode in {CallCode, Call, Create}:
    c.transferBalance(opCode)
    if c.isError():
      c.rollback()
      c.nextProc()
      return

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

proc registerAccountForDeletion*(c: Computation, beneficiary: EthAddress) =
  c.touchedAccounts.incl beneficiary
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
