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
  # debugging flag
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ./compu_helper,
  ./interpreter/[forks_list, gas_costs, gas_meter,
                 op_codes, op_handlers, op_handlers/oph_defs],
  ./code_stream,
  ./v2types,
  chronicles,
  macros

logScope:
  topics = "vm opcode"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

template handleStopDirective(k: var Vm2Ctx) =
  trace "op: Stop"
  if not k.cpt.code.atEnd() and k.cpt.tracingEnabled:
    # we only trace `REAL STOP` and ignore `FAKE STOP`
    k.cpt.opIndex = k.cpt.traceOpCodeStarted(Stop)
    k.cpt.traceOpCodeEnded(Stop, k.cpt.opIndex)


template handleFixedGasCostsDirective(fork: Fork; op: Op; k: var Vm2Ctx) =
    if k.cpt.tracingEnabled:
      k.cpt.opIndex = k.cpt.traceOpCodeStarted(op)

    k.cpt.gasMeter.consumeGas(k.cpt.gasCosts[op].cost, reason = $op)
    vmOpHandlers[fork][op].run(k)

    if k.cpt.tracingEnabled:
      k.cpt.traceOpCodeEnded(op, k.cpt.opIndex)


template handleOtherDirective(fork: Fork; op: Op; k: var Vm2Ctx) =
    if k.cpt.tracingEnabled:
      k.cpt.opIndex = k.cpt.traceOpCodeStarted(op)

    vmOpHandlers[fork][op].run(k)

    if k.cpt.tracingEnabled:
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

    # Inner case/switch => Fork
    let branchOnFork = quote do: `forkArg`
    var forkCaseSubExpr = nnkCaseStmt.newTree(branchOnFork)
    for fork in Fork:

      let
        asFork = quote do: Fork(`fork`)
        asOp = quote do: Op(`op`)

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

      forkCaseSubExpr.add nnkOfBranch.newTree(
        newIdentNode(fork.toSymbolName),
        branchStmt)

    # Wrap innner case/switch into outer case/switch
    let branchStmt = block:
      case op
      of Create, Create2, Call, CallCode, DelegateCall, StaticCall:
        quote do:
          `forkCaseSubExpr`
          if not c.continuation.isNil:
            break
      of Stop, Return, Revert, SelfDestruct:
        quote do:
          `forkCaseSubExpr`
          break
      else:
        quote do:
          `forkCaseSubExpr`

    result.add nnkOfBranch.newTree(
      newIdentNode(op.toSymbolName),
      branchStmt)

  when breakCircularDependency:
    echo ">>> ", result.repr


macro genDispatchMatrix(fork: Fork; op: Op; k: Vm2Ctx): untyped =
  result = fork.toCaseStmt(op, k)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc selectVM*(c: Computation, fork: Fork) {.gcsafe.} =
  ## Op code execution handler main loop.
  var desc: Vm2Ctx
  desc.cpt = c

  if c.tracingEnabled:
    c.prepareTracer()

  while true:
    c.instr = c.code.next()

    # Note Mamy's observation in opTableToCaseStmt() from original VM
    # regarding computed goto
    #
    # ackn:
    #   #{.computedGoto.}
    #   # computed goto causing stack overflow, it consumes a lot of space
    #   # we could use manual jump table instead
    #   # TODO lots of macro magic here to unravel, with chronicles...
    #   # `c`.logger.log($`c`.stack & "\n\n", fgGreen)

    when defined(release):
      #
      # FIXME: OS case list below needs to be adjusted
      #
      when defined(windows):
        when defined(cpu64):
          {.warning: "*** Win64/VM2 handler switch => computedGoto".}
          {.computedGoto, optimization: speed.}
        else:
          # computedGoto is not compiling on github/ci (out of memory) -- jordan
          {.warning: "*** Win32/VM2 handler switch => optimisation disabled".}
          # {.computedGoto, optimization: speed.}

      elif defined(linux):
        when defined(cpu64):
          {.warning: "*** Linux64/VM2 handler switch => computedGoto".}
          {.computedGoto, optimization: speed.}
        else:
          {.warning: "*** Linux32/VM2 handler switch => computedGoto".}
          {.computedGoto, optimization: speed.}

      elif defined(macosx):
        when defined(cpu64):
          {.warning: "*** MacOs64/VM2 handler switch => computedGoto".}
          {.computedGoto, optimization: speed.}
        else:
          {.warning: "*** MacOs32/VM2 handler switch => computedGoto".}
          {.computedGoto, optimization: speed.}

      else:
        {.warning: "*** Unsupported OS => no handler switch optimisation".}

    genDispatchMatrix(fork, c.instr, desc)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
