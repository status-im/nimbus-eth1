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

    if k.cpt.tracingEnabled:
      k.cpt.traceOpCodeEnded(op, k.cpt.opIndex)


template handleOtherDirective(fork: EVMFork; op: Op; k: var Vm2Ctx) =
    if k.cpt.tracingEnabled:
      k.cpt.opIndex = k.cpt.traceOpCodeStarted(op)

    vmOpHandlers[fork][op].run(k)

    # If continuation is not nil, traceOpCodeEnded will be called in executeOpcodes.
    # FIXME-Adam: I hate this. It is horribly convoluted. Can we fix this? I'm
    # hesitant to mess with this code too much, because I worry that I'll wreck
    # performance. I should really do some performance tests.
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
      # FIXME-manyOpcodesNowRequireContinuations
      #
      # Note that Sload and the ones following it are on this list because
      # they call asyncChainTo (and so they set a pendingAsyncOperation and
      # a continuation that needs to be noticed by the interpreter_dispatch
      # loop).
      #
      # This is looking very ugly. Is there a better way of doing it?
      #of Create, Create2, Call, CallCode, DelegateCall, StaticCall, Sload, Sstore, Balance, SelfBalance, CodeSize, CodeCopy, ExtCodeSize, ExtCodeCopy, ExtCodeHash, CallDataCopy, ReturnDataCopy, Blockhash, Sha3, Mload, Mstore, Mstore8, Log0, Log1, Log2, Log3, Log4, Jump, Jumpi:
      #  quote do:
      #    `forkCaseSubExpr`
      #    if not `k`.cpt.continuation.isNil:
      #      break
      of Stop, Return, Revert, SelfDestruct:
        quote do:
          `forkCaseSubExpr`
          break
      else:
        quote do:
          `forkCaseSubExpr`
          # AARDVARK let's add this down here
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
  # FIXME-manyOpcodesNowRequireContinuations
  # See the comment above regarding why this list is so huge.
  #of Create, Create2, Call, CallCode, DelegateCall, StaticCall, Sload, Sstore, Balance, SelfBalance, CodeSize, CodeCopy, ExtCodeSize, ExtCodeCopy, ExtCodeHash, CallDataCopy, ReturnDataCopy, Blockhash, Sha3, Mload, Mstore, Mstore8, Log0, Log1, Log2, Log3, Log4, Jump, Jumpi:
  #  if not k.cpt.continuation.isNil:
  #    break
  of Return, Revert, SelfDestruct:
    break
  else:
    # AARDVARK added this down here
    if not k.cpt.continuation.isNil:
      break
    discard

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
