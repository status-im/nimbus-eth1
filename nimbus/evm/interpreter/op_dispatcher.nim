# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
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
  ../evm_errors,
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

template handleStopDirective(cpt: VmCpt) =
  #trace "op: Stop"
  if not cpt.code.atEnd() and cpt.tracingEnabled:
    # we only trace `REAL STOP` and ignore `FAKE STOP`
    cpt.opIndex = cpt.traceOpCodeStarted(Stop)
    cpt.traceOpCodeEnded(Stop, cpt.opIndex)


template handleFixedGasCostsDirective(fork: EVMFork; op: Op; cpt: VmCpt) =
  if cpt.tracingEnabled:
    cpt.opIndex = cpt.traceOpCodeStarted(op)

  ? cpt.opcodeGasCost(op, cpt.gasCosts[op].cost, reason = $op)
  ? vmOpHandlers[fork][op].run(cpt)

  # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
  if cpt.tracingEnabled and cpt.continuation.isNil:
    cpt.traceOpCodeEnded(op, cpt.opIndex)


template handleOtherDirective(fork: EVMFork; op: Op; cpt: VmCpt) =
  if cpt.tracingEnabled:
    cpt.opIndex = cpt.traceOpCodeStarted(op)

  ? vmOpHandlers[fork][op].run(cpt)

  # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
  if cpt.tracingEnabled and cpt.continuation.isNil:
    cpt.traceOpCodeEnded(op, cpt.opIndex)

# ------------------------------------------------------------------------------
# Private, big nasty doubly nested case matrix generator
# ------------------------------------------------------------------------------

# reminiscent of Mamy's opTableToCaseStmt() from original VM
proc toCaseStmt(forkArg, opArg, cpt: NimNode): NimNode =

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
      let gcTable = forkToGck[fork]

      let branchStmt = block:
        if op == Stop:
          quote do:
            handleStopDirective(`cpt`)
        elif gcTable[op] == GckFixed:
          quote do:
            handleFixedGasCostsDirective(`asFork`,`asOp`,`cpt`)
        else:
          quote do:
            handleOtherDirective(`asFork`,`asOp`,`cpt`)

      forkCaseSubExpr.add nnkOfBranch.newTree(asFork, branchStmt)

    # Wrap innner case/switch into outer case/switch
    let branchStmt = block:
      case op
      of Stop, Return, Revert, SelfDestruct:
        quote do:
          `forkCaseSubExpr`
          break
      else:
        # Anyway, the point is that now we might as well just do this check
        # for *every* opcode (other than Return/Revert/etc, which need to
        # break no matter what).
        quote do:
          `forkCaseSubExpr`
          if not `cpt`.continuation.isNil:
            break

    result.add nnkOfBranch.newTree(asOp, branchStmt)

  when isChatty:
    echo ">>> ", result.repr

# ------------------------------------------------------------------------------
# Public macros/functions
# ------------------------------------------------------------------------------

macro genOptimisedDispatcher*(fork: EVMFork; op: Op; cpt: VmCpt): untyped =
  result = fork.toCaseStmt(op, cpt)


template genLowMemDispatcher*(fork: EVMFork; op: Op; cpt: VmCpt) =
  if op == Stop:
    handleStopDirective(cpt)
    break

  if BaseGasCosts[op].kind == GckFixed:
    handleFixedGasCostsDirective(fork, op, cpt)
  else:
    handleOtherDirective(fork, op, cpt)

  case cpt.instr
  of Return, Revert, SelfDestruct:
    break
  else:
    # FIXME-manyOpcodesNowRequireContinuations
    if not cpt.continuation.isNil:
      break

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isChatty:

  import ../types

  proc optimised(cpt: VmCpt, fork: EVMFork): EvmResultVoid {.compileTime.} =
    while true:
      genOptimisedDispatcher(fork, cpt.instr, desc)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
