# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  tables, macros,
  chronicles,
  ./interpreter/op_handlers/oph_defs,
  ./interpreter/[forks_list, op_handlers, op_codes, v2gas_costs, gas_meter],
  ./code_stream, ./v2types, ./v2precompiles, ./stack

logScope:
  topics = "vm opcode"

proc opTableToCaseStmt(c: NimNode; fork: Fork): NimNode =

  let instr = quote do: `c`.instr
  result = nnkCaseStmt.newTree(instr)

  # Add a branch for each (opcode, proc) pair
  # We dispatch to the next instruction at the end of each branch
  for op in Op:
    let asOp = quote do: Op(`op`) # TODO: unfortunately when passing to runtime, ops are transformed into int
    let branchStmt = block:
      if op == Stop:
        quote do:
          trace "op: Stop"
          if not `c`.code.atEnd() and `c`.tracingEnabled:
            # we only trace `REAL STOP` and ignore `FAKE STOP`
            `c`.opIndex = `c`.traceOpCodeStarted(`asOp`)
            `c`.traceOpCodeEnded(`asOp`, `c`.opIndex)
          break
      else:
        if BaseGasCosts[op].kind == GckFixed:
          quote do:
            if `c`.tracingEnabled:
              `c`.opIndex = `c`.traceOpCodeStarted(`asOp`)
            `c`.gasMeter.consumeGas(`c`.gasCosts[`asOp`].cost, reason = $`asOp`)
            var desc: Vm2Ctx
            desc.cpt = `c`
            vm2OpHandlers[Fork(`fork`)][`asOp`].exec.run(desc)
            if `c`.tracingEnabled:
              `c`.traceOpCodeEnded(`asOp`, `c`.opIndex)
            when `asOp` in {Create, Create2, Call, CallCode, DelegateCall, StaticCall}:
              if not `c`.continuation.isNil:
                return
        else:
          quote do:
            if `c`.tracingEnabled:
              `c`.opIndex = `c`.traceOpCodeStarted(`asOp`)
            var desc: Vm2Ctx
            desc.cpt = `c`
            vm2OpHandlers[Fork(`fork`)][`asOp`].exec.run(desc)
            if `c`.tracingEnabled:
              `c`.traceOpCodeEnded(`asOp`, `c`.opIndex)
            when `asOp` in {Create, Create2, Call, CallCode, DelegateCall, StaticCall}:
              if not `c`.continuation.isNil:
                return
            when `asOp` in {Return, Revert, SelfDestruct}:
              break

    result.add nnkOfBranch.newTree(
      newIdentNode($op),
      branchStmt
    )

  # Wrap the case statement in while true + computed goto
  result = quote do:
    if `c`.tracingEnabled:
      `c`.prepareTracer()
    while true:
      `instr` = `c`.code.next()
      #{.computedGoto.}
      # computed goto causing stack overflow, it consumes a lot of space
      # we could use manual jump table instead
      # TODO lots of macro magic here to unravel, with chronicles...
      # `c`.logger.log($`c`.stack & "\n\n", fgGreen)
      `result`


macro genFrontierDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkFrontier)

macro genHomesteadDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkHomestead)

macro genTangerineDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkTangerine)

macro genSpuriousDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkSpurious)

macro genByzantiumDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkByzantium)

macro genConstantinopleDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkConstantinople)

macro genPetersburgDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkPetersburg)

macro genIstanbulDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkIstanbul)

macro genBerlinDispatch(c: Computation): untyped =
  result = opTableToCaseStmt(c, FkBerlin)

proc frontierVM(c: Computation) =
  genFrontierDispatch(c)

proc homesteadVM(c: Computation) =
  genHomesteadDispatch(c)

proc tangerineVM(c: Computation) =
  genTangerineDispatch(c)

proc spuriousVM(c: Computation) {.gcsafe.} =
  genSpuriousDispatch(c)

proc byzantiumVM(c: Computation) {.gcsafe.} =
  genByzantiumDispatch(c)

proc constantinopleVM(c: Computation) {.gcsafe.} =
  genConstantinopleDispatch(c)

proc petersburgVM(c: Computation) {.gcsafe.} =
  genPetersburgDispatch(c)

proc istanbulVM(c: Computation) {.gcsafe.} =
  genIstanbulDispatch(c)

proc berlinVM(c: Computation) {.gcsafe.} =
  genBerlinDispatch(c)

proc selectVM(c: Computation, fork: Fork) {.gcsafe.} =
  # TODO: Optimise getting fork and updating opCodeExec only when necessary
  case fork
  of FkFrontier:
    c.frontierVM()
  of FkHomestead:
    c.homesteadVM()
  of FkTangerine:
    c.tangerineVM()
  of FkSpurious:
    c.spuriousVM()
  of FkByzantium:
    c.byzantiumVM()
  of FkConstantinople:
    c.constantinopleVM()
  of FkPetersburg:
    c.petersburgVM()
  of FkIstanbul:
    c.istanbulVM()
  else:
    c.berlinVM()

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
      c.setError(&"Opcode Dispatch Error msg={e.msg}, depth={c.msg.depth}", true)

  if c.isError() and c.continuation.isNil:
    if c.tracingEnabled: c.traceError()
    debug "executeOpcodes error", msg=c.error.info
