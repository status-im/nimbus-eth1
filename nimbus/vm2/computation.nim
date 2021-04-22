# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when defined(evmc_enabled):
  {.fatal: "Flags \"evmc_enabled\" and \"vm2_enabled\" are mutually exclusive"}

import
  chronicles, strformat, macros, options,
  sets, eth/[common, keys],
  ../constants,
  ./compu_helper,
  ./interpreter/[op_codes, gas_meter, gas_costs, forks_list],
  ./code_stream, ./memory, ./message, ./stack, ./types, ./state,
  ../db/accounts_cache,
  ./precompiles,
  ./transaction_tracer, ../utils

logScope:
  topics = "vm computation"

proc generateContractAddress(c: Computation, salt: Uint256): EthAddress =
  if c.msg.kind == evmcCreate:
    let creationNonce = c.vmState.readOnlyStateDb().getNonce(c.msg.sender)
    result = generateAddress(c.msg.sender, creationNonce)
  else:
    result = generateSafeAddress(c.msg.sender, salt, c.msg.data)


proc newComputation*(vmState: BaseVMState, message: Message, salt= 0.u256): Computation =
  new result
  result.vmState = vmState
  result.msg = message
  result.memory = Memory()
  result.stack = newStack()
  result.returnStack = @[]
  result.gasMeter.init(message.gas)
  result.touchedAccounts = initHashSet[EthAddress]()
  result.suicides = initHashSet[EthAddress]()

  if result.msg.isCreate():
    result.msg.contractAddress = result.generateContractAddress(salt)
    result.code = newCodeStream(message.data)
    message.data = @[]
  else:
    result.code = newCodeStream(vmState.readOnlyStateDb.getCode(message.codeAddress))

proc isOriginComputation*(c: Computation): bool =
  # Is this computation the computation initiated by a transaction
  c.msg.sender == c.vmState.txOrigin

template isSuccess*(c: Computation): bool =
  c.error.isNil

template isError*(c: Computation): bool =
  not c.isSuccess

func shouldBurnGas*(c: Computation): bool =
  c.isError and c.error.burnsGas

proc isSuicided*(c: Computation, address: EthAddress): bool =
  result = address in c.suicides

proc snapshot*(c: Computation) =
  c.savePoint = c.vmState.accountDb.beginSavePoint()

proc commit*(c: Computation) =
  c.vmState.accountDb.commit(c.savePoint)

proc dispose*(c: Computation) {.inline.} =
  c.vmState.accountDb.safeDispose(c.savePoint)
  c.savePoint = nil

proc rollback*(c: Computation) =
  c.vmState.accountDb.rollback(c.savePoint)

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
      db.setCode(storageAddr, contractCode)
    result = true
  else:
    if fork < FkHomestead or fork >= FkByzantium: c.output = @[]
    result = false

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
    db.incNonce(c.msg.sender)

    # We add this to the access list _before_ taking a snapshot.
    # Even if the creation fails, the access-list change should not be rolled back
    # EIP2929
    if c.fork >= FkBerlin:
      db.accessList(c.msg.contractAddress)

  c.snapshot()

  if c.vmState.readOnlyStateDb().hasCodeOrNonce(c.msg.contractAddress):
    c.setError("Address collision when creating contract address={c.msg.contractAddress.toHex}", true)
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
    let fork = c.fork
    let contractFailed = not c.writeContract(fork)
    if contractFailed and fork >= FkHomestead:
      c.setError(&"writeContract failed, depth={c.msg.depth}", true)

  if c.isSuccess:
    c.commit()
  else:
    c.rollback()

proc beforeExec(c: Computation): bool =
  if not c.msg.isCreate:
    c.beforeExecCall()
    false
  else:
    c.beforeExecCreate()

proc afterExec(c: Computation) =
  if not c.msg.isCreate:
    c.afterExecCall()
  else:
    c.afterExecCreate()

template chainTo*(c, toChild: Computation, after: untyped) =
  c.child = toChild
  c.continuation = proc() =
    after

proc execCallOrCreate*(cParam: Computation) =
  var (c, before) = (cParam, true)
  defer:
    while not c.isNil:
      c.dispose()
      c = c.parent

  # No actual recursion, but simulate recursion including before/after/dispose.
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
    (c.continuation)()

proc merge*(c, child: Computation) =
  c.logEntries.add child.logEntries
  c.gasMeter.refundGas(child.gasMeter.gasRefunded)
  c.suicides.incl child.suicides
  c.touchedAccounts.incl child.touchedAccounts

proc getGasRefund*(c: Computation): GasInt =
  if c.isSuccess:
    result = c.gasMeter.gasRefunded

proc refundSelfDestruct*(c: Computation) =
  let cost = gasFees[c.fork][RefundSelfDestruct]
  c.gasMeter.refundGas(cost * c.suicides.len)


proc traceError*(c: Computation) {.inline.} =
  c.vmState.tracer.traceError(c)


import interpreter_dispatch

proc executeOpcodes(c: Computation) =
  let fork = c.fork

  block:
    if not c.continuation.isNil:
      c.continuation = nil
    elif c.execPrecompiles(fork):
      break

    try:
      c.selectVM(fork)
    except CatchableError as e:
      c.setError(
        &"Opcode Dispatch Error msg={e.msg}, depth={c.msg.depth}", true)

  if c.isError() and c.continuation.isNil:
    if c.tracingEnabled: c.traceError()
    debug "executeOpcodes error", msg=c.error.info
