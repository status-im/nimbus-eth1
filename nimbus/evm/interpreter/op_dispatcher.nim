# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

const
  # debugging flag, dump macro info when asked for
  noisy {.intdefine.}: int = 0
  # isNoisy {.used.} = noisy > 0
  isChatty {.used.} = noisy > 1

import
  ../code_stream,
  ../computation,
  ../../common/evmforks,
  ./gas_costs,
  ./gas_meter,
  ./op_codes,
  ./op_handlers,
  ./op_handlers/oph_defs,
  chronicles,
  macros

export
  EVMFork, Op,
  oph_defs,
  gas_meter

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

template handleStopDirective(k: var Vm2Ctx) =
  #trace "op: Stop"
  if not k.cpt.code.atEnd() and k.cpt.tracingEnabled:
    # we only trace `REAL STOP` and ignore `FAKE STOP`
    k.cpt.opIndex = k.cpt.traceOpCodeStarted(Stop)
    k.cpt.traceOpCodeEnded(Stop, k.cpt.opIndex)


template handleFixedGasCostsDirective(fork: EVMFork; op: Op; k: var Vm2Ctx) =
    if k.cpt.tracingEnabled:
      k.cpt.opIndex = k.cpt.traceOpCodeStarted(op)

    k.cpt.gasMeter.consumeGas(k.cpt.gasCosts[op].cost, reason = $op)
    vmOpHandlers[fork][op].run(k)

    # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
    if k.cpt.tracingEnabled and k.cpt.continuation.isNil:
      k.cpt.traceOpCodeEnded(op, k.cpt.opIndex)


template handleOtherDirective(fork: EVMFork; op: Op; k: var Vm2Ctx) =
    if k.cpt.tracingEnabled:
      k.cpt.opIndex = k.cpt.traceOpCodeStarted(op)

    vmOpHandlers[fork][op].run(k)

    # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
    if k.cpt.tracingEnabled and k.cpt.continuation.isNil:
      k.cpt.traceOpCodeEnded(op, k.cpt.opIndex)

# ------------------------------------------------------------------------------
# Private, big nasty doubly nested case matrix generator
# ------------------------------------------------------------------------------

# reminiscent of Mamy's opTableToCaseStmt() from original VM
proc toCaseStmt(forkArg, opArg, k: NimNode): NimNode =

  # Outer case/switch => Op
  let branchOnOp = quote do: `opArg`
  result = nnkCaseStmt.newTree(branchOnOp)
  for op in Op:
    let asOp = quote do: Op(`op`)

    # Inner case/switch => Fork
    let branchOnFork = quote do: `forkArg`
    var forkCaseSubExpr = nnkCaseStmt.newTree(branchOnFork)
    for fork in EVMFork:
      let asFork = quote do: EVMFork(`fork`)

      let branchStmt = block:
        if op == Stop:
          quote do:
            handleStopDirective(`k`)
        elif BaseGasCosts[op].kind == GckFixed:
          quote do:
            handleFixedGasCostsDirective(`asFork`,`asOp`,`k`)
        else:
          quote do:
            handleOtherDirective(`asFork`,`asOp`,`k`)

      forkCaseSubExpr.add nnkOfBranch.newTree(asFork, branchStmt)

    # Wrap innner case/switch into outer case/switch
    let branchStmt = block:
      case op
      of Stop, Return, Revert, SelfDestruct:
        quote do:
          `forkCaseSubExpr`
          break
      else:
        # FIXME-manyOpcodesNowRequireContinuations
        # We used to have another clause in this case statement for various
        # opcodes that *don't* need to check for a continuation. But now
        # there are many opcodes that need to, because they call asyncChainTo
        # (and so they set a pendingAsyncOperation and a continuation that
        # needs to be noticed by the interpreter_dispatch loop). And that
        # will become even more true once we implement speculative execution,
        # because that will mean that even reading from the stack might
        # require waiting.
        #
        # Anyway, the point is that now we might as well just do this check
        # for *every* opcode (other than Return/Revert/etc, which need to
        # break no matter what).
        quote do:
          `forkCaseSubExpr`
          if not `k`.cpt.continuation.isNil:
            break

    result.add nnkOfBranch.newTree(asOp, branchStmt)

  when isChatty:
    echo ">>> ", result.repr

# ------------------------------------------------------------------------------
# Public macros/functions
# ------------------------------------------------------------------------------

macro genOptimisedDispatcher*(fork: EVMFork; op: Op; k: Vm2Ctx): untyped =
  result = fork.toCaseStmt(op, k)


template genLowMemDispatcher*(fork: EVMFork; op: Op; k: Vm2Ctx) =
  if op == Stop:
    handleStopDirective(k)
    break

  if BaseGasCosts[op].kind == GckFixed:
    handleFixedGasCostsDirective(fork, op, k)
  else:
    handleOtherDirective(fork, op, k)

  case c.instr
  of Return, Revert, SelfDestruct:
    break
  else:
    # FIXME-manyOpcodesNowRequireContinuations
    if not k.cpt.continuation.isNil:
      break

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isChatty:

  import ../types

  proc optimised(c: Computation, fork: EVMFork) {.compileTime.} =
    var desc: Vm2Ctx
    while true:
      genOptimisedDispatcher(fork, desc.cpt.instr, desc)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
