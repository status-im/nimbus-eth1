# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[macros, strformat],
  chronicles,
  stew/[byteutils, assign2],
  ../constants,
  ../db/ledger,
  ../core/eip8037,
  ../transaction/[call_types, eoa_delegation],
  ./interpreter/[op_dispatcher],
  ./interpreter/op_handlers/oph_helpers,
  ./[code_stream, computation, evm_errors, message, precompiles, state, types]

logScope:
  topics = "vm opcode"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc runVM(
    c: VmCpt,
    fork: static EVMFork,
    tracingEnabled: static bool,
): EvmResultVoid =
  ## VM instruction handler main loop - for each fork, a distinc version of
  ## this function is instantiated so that selection of fork-specific
  ## versions of functions happens only once

  when tracingEnabled:
    c.prepareTracer()

  while true:
    {.computedGoto.}
    c.instr = c.code.next()

    dispatchInstr(fork, tracingEnabled, c.instr, c)

  ok()

macro selectVM(v: VmCpt, fork: EVMFork, tracingEnabled: bool): EvmResultVoid =
  # Generate opcode dispatcher that calls selectVM with a literal for each fork:
  #
  # case fork
  # of A: runVM(v, A, ...)
  # ...

  let caseStmt = nnkCaseStmt.newTree(fork)
  for fork in EVMFork:
    let
      forkVal = quote:
        `fork`
      call = quote:
        case `tracingEnabled`
        of false: runVM(`v`, `fork`, false)
        of true: runVM(`v`, `fork`, true)

    caseStmt.add nnkOfBranch.newTree(forkVal, call)
  caseStmt

proc prepareDispatch(params: CallParams, c: Computation): EvmResultVoid =
  let
    vmState = c.vmState
    ledger = vmState.ledger

  if vmState.balTrackerEnabled:
    vmState.balTracker.trackAddressAccess(c.msg.contractAddress)

  var
    code =
      if params.isCreate:
        if ledger.originalAccountEmpty(c.msg.contractAddress):
          ? c.gasMeter.chargeStateGas(CREATE_ACCOUNT_STATE_GAS, "prepareDispatch create new account")
        CodeBytesRef.init(params.input)
      else:
        if params.value.isZero.not and not ledger.accountExists(c.msg.contractAddress):
          ? c.gasMeter.chargeStateGas(CREATE_ACCOUNT_STATE_GAS, "prepareDispatch call new account")
        assign(c.msg.data, params.input)
        getRecipientCode(vmState, c.msg)

  if MsgFlags.Delegated in c.msg.flags:
    # The delegated account access must be charged before its code is read,
    # or an OOG here would wrongly add the target account to the witness.
    let delegatedGas = c.gasEip8038AccountCheck(c.msg.delegateTo)
    ? c.gasMeter.consumeGas(delegatedGas, "prepareDispatch delegatedGas")

    if vmState.balTrackerEnabled:
      vmState.balTracker.trackAddressAccess(c.msg.delegateTo)
    code = vmState.readOnlyLedger.getCode(c.msg.delegateTo)

  c.setCode(code)
  ok()

proc authAndDelegation(params: CallParams, c: Computation): EvmResultVoid =
  ? params.setDelegation(c)
  c.vmState.authStateGasUsed = c.frameStateGasUsed()
  c.msg.stateGasReservoir = c.gasMeter.stateGasLeft
  c.gasMeter.stateGasSpilled = 0
  params.prepareDispatch(c)

proc topFrameAuthAndDelegation(params: CallParams, c: Computation): bool =
  let
    prepReservoir = c.msg.stateGasReservoir

  c.beginSavePoint()
  params.authAndDelegation(c).isOkOr:
    c.rollback()
    c.msg.stateGasReservoir = prepReservoir
    c.vmState.authStateGasUsed = 0
    c.refillFrameStateGas()
    c.setError($error.code, true)
    return false

  c.commit()
  true

proc beforeExecCall(c: Computation, params: CallParams): bool =
  if c.msg.depth == 0 and c.fork >= FkAmsterdam and MsgFlags.SystemCall notin c.msg.flags:
    if not params.topFrameAuthAndDelegation(c):
      return true

  c.beginSavePoint()
  if c.msg.kind == CallKind.Call:
    c.vmState.mutateLedger:
      if c.balTrackerEnabled:
        c.vmState.balTracker.trackSubBalanceChange(c.msg.sender, c.msg.value)
        ledger.subBalance(c.msg.sender, c.msg.value)
        c.vmState.balTracker.trackAddBalanceChange(c.msg.contractAddress, c.msg.value)
        ledger.addBalance(c.msg.contractAddress, c.msg.value, checkEmptyAccount = c.fork < FkParis)
      else:
        ledger.subBalance(c.msg.sender, c.msg.value)
        ledger.addBalance(c.msg.contractAddress, c.msg.value, checkEmptyAccount = c.fork < FkParis)

    if c.fork >= FkAmsterdam:
      # EIP-7708: Emit transfer log for ETH-tx or contract call and CALL op code
      c.emitTransferLog()

  false

proc afterExecCall(c: Computation) =
  ## Collect all of the accounts that *may* need to be deleted based on EIP161
  ## https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  ## also see: https://github.com/ethereum/EIPs/issues/716

  if c.isError or c.fork >= FkByzantium:
    if c.msg.contractAddress == RIPEMD_ADDR:
      # Special case to account for geth+parity bug
      c.vmState.ledger.ripemdSpecial()

proc beforeExecCreate(c: Computation, params: CallParams): bool =
  if c.msg.depth == 0:
    if not c.incrementNonce():
      return true

    if c.fork >= FkAmsterdam:
      if not params.topFrameAuthAndDelegation(c):
        return true

    if not c.accountDeployable():
      return true

  c.beginSavePoint()

  c.vmState.mutateLedger:
    if c.balTrackerEnabled:
      c.vmState.balTracker.trackSubBalanceChange(c.msg.sender, c.msg.value)
      ledger.subBalance(c.msg.sender, c.msg.value)
      c.vmState.balTracker.trackAddBalanceChange(c.msg.contractAddress, c.msg.value)
      ledger.addBalance(c.msg.contractAddress, c.msg.value, checkEmptyAccount = c.fork < FkParis)
      ledger.clearStorage(c.msg.contractAddress)
      if c.fork >= FkSpurious:
        c.vmState.balTracker.trackIncNonceChange(c.msg.contractAddress)
        ledger.incNonce(c.msg.contractAddress)
    else:
      ledger.subBalance(c.msg.sender, c.msg.value)
      ledger.addBalance(c.msg.contractAddress, c.msg.value, checkEmptyAccount = c.fork < FkParis)
      ledger.clearStorage(c.msg.contractAddress)
      if c.fork >= FkSpurious:
        # EIP161 nonce incrementation
        ledger.incNonce(c.msg.contractAddress)

  if c.fork >= FkAmsterdam:
    # EIP-7708: Emit transfer log for contract creation and CREATE op code
    c.emitTransferLog()

  return false

proc afterExecCreate(c: Computation) =
  if c.isSuccess:
    # This can change `c.isSuccess`.
    c.writeContract()
    # Contract code should never be returned to the caller.  Only data from
    # `REVERT` is returned after a create.  Clearing in this branch covers the
    # right cases, particularly important with EVMC where it must be cleared.
    c.output.reset()

const MsgKindToOp: array[CallKind, Op] =
  [Call, DelegateCall, CallCode, Create, Create2]

func msgToOp(msg: Message): Op =
  if MsgFlags.Static in msg.flags:
    return StaticCall
  MsgKindToOp[msg.kind]

proc beforeExec(c: Computation, params: CallParams): bool =
  if c.msg.depth > 0:
    c.vmState.captureEnter(
      c,
      msgToOp(c.msg),
      c.msg.sender,
      c.msg.contractAddress,
      c.msg.data,
      c.msg.gas,
      c.msg.value,
    )

  if c.msg.isCreate:
    c.beforeExecCreate(params)
  else:
    c.beforeExecCall(params)

proc afterExec(c: Computation) =
  if not c.msg.isCreate:
    c.afterExecCall()
  else:
    c.afterExecCreate()

  if c.isSuccess:
    c.commit()
  else:
    c.refillFrameStateGas()
    c.rollback()

  if c.msg.depth > 0:
    let gasUsed = c.msg.gas - c.gasMeter.gasRemaining
    c.vmState.captureExit(c, c.output, gasUsed, c.errorOpt)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

template handleEvmError(x: EvmErrorObj) =
  let
    msg = $x.code
    depth = $(c.msg.depth + 1) # plus one to match tracer depth, and avoid confusion
  c.setError("Opcode Dispatch Error: " & msg & ", depth=" & depth, true)

proc executeOpcodes*(c: Computation) =
  let fork = c.fork

  block blockOne:
    let cont = c.continuation
    if cont.isNil:
      if MsgFlags.Precompile in c.msg.flags:
        let precompile = c.fork.getPrecompile(c.msg.codeAddress)
        c.execPrecompile(precompile[])
        break blockOne
    else:
      c.continuation = nil
      cont(c).isOkOr:
        handleEvmError(error)
        break blockOne

      let nextCont = c.continuation
      if not nextCont.isNil:
        # Return up to the caller, which will run the child
        # and then call this proc again.
        break blockOne

      # traceOpCodeEnded is normally called directly after opcode execution
      # but in the case that a continuation is created, it must run after that
      # continuation has finished
      if c.tracingEnabled:
        c.traceOpCodeEnded(c.instr, c.opIndex)

    if c.instr == Return or c.instr == Revert or c.instr == SelfDestruct:
      break blockOne

    c.selectVM(fork, c.tracingEnabled).isOkOr:
      handleEvmError(error)
      break blockOne # this break is not needed but make the flow clear

  if c.isError() and c.continuation.isNil:
    if c.tracingEnabled:
      c.traceError()

proc execCallOrCreate*(cParam: Computation, params: CallParams) =
  var (c, before) = (cParam, true)

  # No actual recursion, but simulate recursion including before/after/dispose.
  while true:
    while true:
      if before and c.beforeExec(params):
        break
      c.executeOpcodes()
      if c.continuation.isNil:
        c.child = nil
        c.afterExec()
        break

      # recurse into the child computation
      let child = c.child
      child.parent = c
      before = true
      c = child
    if c.parent.isNil:
      break
    c.dispose()

    # recurse out: child is still owned by the parent
    before = false
    c = c.parent

  while not c.isNil:
    let p = c.parent
    c.dispose()
    c.child = nil
    c = p

func postExecComputation*(c: Computation) =
  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
  c.vmState.status = c.isSuccess

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
