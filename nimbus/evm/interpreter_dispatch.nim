# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  pkg/[chronicles, chronos, stew/byteutils],
  ".."/[constants, db/ledger],
  "."/[code_stream, computation, evm_errors],
  "."/[message, precompiles, state, types],
  ./interpreter/op_dispatcher

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

proc beforeExecCall(c: Computation) =
  c.snapshot()
  if c.msg.kind == EVMC_CALL:
    c.vmState.mutateStateDB:
      db.subBalance(c.msg.sender, c.msg.value)
      db.addBalance(c.msg.contractAddress, c.msg.value)

proc afterExecCall(c: Computation) =
  ## Collect all of the accounts that *may* need to be deleted based on EIP161
  ## https://github.com/ethereum/EIPs/blob/master/EIPS/eip-161.md
  ## also see: https://github.com/ethereum/EIPs/issues/716

  if c.isError or c.fork >= FkByzantium:
    if c.msg.contractAddress == RIPEMD_ADDR:
      # Special case to account for geth+parity bug
      c.vmState.stateDB.ripemdSpecial()

  if c.isSuccess:
    c.commit()
  else:
    c.rollback()

proc beforeExecCreate(c: Computation): bool =
  c.vmState.mutateStateDB:
    let nonce = db.getNonce(c.msg.sender)
    if nonce + 1 < nonce:
      let sender = c.msg.sender.toHex
      c.setError(
        "Nonce overflow when sender=" & sender & " wants to create contract", false
      )
      return true
    db.setNonce(c.msg.sender, nonce + 1)

    # We add this to the access list _before_ taking a snapshot.
    # Even if the creation fails, the access-list change should not be rolled
    # back EIP2929
    if c.fork >= FkBerlin:
      db.accessList(c.msg.contractAddress)

  c.snapshot()

  if c.vmState.readOnlyStateDB().contractCollision(c.msg.contractAddress):
    let blurb = c.msg.contractAddress.toHex
    c.setError("Address collision when creating contract address=" & blurb, true)
    c.rollback()
    return true

  c.vmState.mutateStateDB:
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

const MsgKindToOp: array[CallKind, Op] =
  [Call, DelegateCall, CallCode, Create, Create2, EofCreate]

func msgToOp(msg: Message): Op =
  if EVMC_STATIC in msg.flags:
    return StaticCall
  MsgKindToOp[msg.kind]

proc beforeExec(c: Computation): bool =
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
      let precompile = c.fork.getPrecompile(c.msg.codeAddress)
      if precompile.isSome:
        c.execPrecompile(precompile[])
        break blockOne
    else:
      c.continuation = nil
      cont().isOkOr:
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

when vm_use_recursion:
  # Recursion with tiny stack frame per level.
  proc execCallOrCreate*(c: Computation) =
    if not c.beforeExec():
      c.executeOpcodes()
      while not c.continuation.isNil:
        # If there's a continuation, then it's because there's either
        # a child (i.e. call or create)
        when evmc_enabled:
          c.res = c.host.call(c.child[])
        else:
          execCallOrCreate(c.child)
        c.child = nil
        c.executeOpcodes()
      c.afterExec()
    c.dispose()

else:
  proc execCallOrCreate*(cParam: Computation) =
    var (c, before) = (cParam, true)

    # No actual recursion, but simulate recursion including before/after/dispose.
    while true:
      while true:
        if before and c.beforeExec():
          break
        c.executeOpcodes()
        if c.continuation.isNil:
          c.afterExec()
          break
        (before, c.child, c, c.parent) =
          (true, nil.Computation, c.child, c)
      if c.parent.isNil:
        break
      c.dispose()
      (before, c.parent, c) =
        (false, nil.Computation, c.parent)

    while not c.isNil:
      c.dispose()
      c = c.parent

proc postExecComputation*(c: Computation) =
  if c.isSuccess:
    if c.fork < FkLondon:
      # EIP-3529: Reduction in refunds
      c.refundSelfDestruct()
  c.vmState.status = c.isSuccess
  
# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
