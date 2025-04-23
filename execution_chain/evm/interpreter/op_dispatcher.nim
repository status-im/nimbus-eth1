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
  ../computation,
  ../evm_errors,
  ../../common/evmforks,
  ./gas_costs,
  ./gas_meter,
  ./op_codes,
  ./op_handlers,
  ./op_handlers/oph_defs,
  macros

export EVMFork, Op, oph_defs, gas_meter

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

template handleStopDirective(cpt: VmCpt, tracingEnabled: bool) =
  #trace "op: Stop"
  when tracingEnabled:
    if not cpt.code.atEnd():
      # we only trace `REAL STOP` and ignore `FAKE STOP`
      cpt.opIndex = cpt.traceOpCodeStarted(Stop)
      ?cpt.opcodeGasCost(Stop, 0, tracingEnabled, reason = $Stop)
      cpt.traceOpCodeEnded(Stop, cpt.opIndex)

template handleFixedGasCostsDirective(
    fork: EVMFork, op: Op, cost: GasInt, cpt: VmCpt, tracingEnabled: bool
) =
  when tracingEnabled:
    cpt.opIndex = cpt.traceOpCodeStarted(op)

  ?cpt.opcodeGasCost(op, cost, tracingEnabled, reason = $op)
  ?vmOpHandlers[fork][op].run(cpt)

  # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
  when tracingEnabled:
    if cpt.continuation.isNil:
      cpt.traceOpCodeEnded(op, cpt.opIndex)

template handleOtherDirective(fork: EVMFork, op: Op, cpt: VmCpt, tracingEnabled: bool) =
  when tracingEnabled:
    cpt.opIndex = cpt.traceOpCodeStarted(op)

  ?vmOpHandlers[fork][op].run(cpt)

  # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
  when tracingEnabled:
    if cpt.continuation.isNil:
      cpt.traceOpCodeEnded(op, cpt.opIndex)

proc makeCaseDispatcher(forkArg: EVMFork, tracingEnabled: bool, opArg, cpt: NimNode): NimNode =
  # Create a case statement for dispatching opcode to handler for the given
  # fork, taking care to record the gas cost
  # TODO there are several forks for which neither opcodes nor gas costs
  #      changed - these could use the same dispatcher thus saving some space
  #      and compile time
  let gasCosts = forkToSchedule(forkArg)

  result = nnkCaseStmt.newTree(opArg)
  for op in Op:
    let
      asOp = quote: `op`
      handler =
        if op == Stop:
          quote:
            handleStopDirective(`cpt`, `tracingEnabled`)
        elif gasCosts[op].kind == GckFixed:
          let cost = gasCosts[op].cost
          quote:
            handleFixedGasCostsDirective(
              `forkArg`, `op`, `cost`, `cpt`, `tracingEnabled`
            )
        else:
          quote:
            handleOtherDirective(`forkArg`, `op`, `cpt`, `tracingEnabled`)
      branch =
        case op
        of Create, Create2, Call, CallCode, DelegateCall, StaticCall:
          # These opcodes use `chainTo` to create a continuation call which must
          # be handled separately
          quote:
            `handler`
            if not `cpt`.continuation.isNil:
              break

        of Stop, Return, Revert, SelfDestruct:
          quote:
            `handler`
            break
        else:
          handler

    result.add nnkOfBranch.newTree(asOp, branch)

  when isChatty:
    echo ">>> ", result.repr

# ------------------------------------------------------------------------------
# Public macros/functions
# ------------------------------------------------------------------------------

macro dispatchInstr*(
    fork: static EVMFork, tracingEnabled: static bool, op: Op, cpt: VmCpt
): untyped =
  makeCaseDispatcher(fork, tracingEnabled, op, cpt)

# ------------------------------------------------------------------------------
# Debugging ...
# ------------------------------------------------------------------------------

when isMainModule and isChatty:
  import ../types

  proc optimised(cpt: VmCpt): EvmResultVoid {.compileTime.} =
    while true:
      dispatchInstr(FkFrontier, false, cpt.instr, cpt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
