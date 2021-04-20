# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles,
  ./interpreter/[gas_meter, op_handlers, op_handlers/oph_defs, v2gas_costs],
  ./code_stream, ./v2types, ./v2precompiles

logScope:
  topics = "vm opcode"


proc selectVM(c: Computation, fork: Fork) {.gcsafe.} =
  if c.tracingEnabled:
    c.prepareTracer()

  while true:
    c.instr = c.code.next()

    var
      op = c.instr
      desc: Vm2Ctx

    desc.cpt = c

    if op == Stop:
      trace "op: Stop"
      if not c.code.atEnd() and c.tracingEnabled:
        c.opIndex = c.traceOpCodeStarted(Stop)
        c.traceOpCodeEnded(Stop, c.opIndex)
      break

    if c.tracingEnabled:
      c.opIndex = c.traceOpCodeStarted(op)
    if BaseGasCosts[op].kind == GckFixed:
      c.gasMeter.consumeGas(c.gasCosts[op].cost, reason = $op)

    opHandlersRun(fork, op, desc)

    if c.tracingEnabled:
      c.traceOpCodeEnded(op, c.opIndex)

    case op
    of Create, Create2, Call, CallCode, DelegateCall, StaticCall:
      if not c.continuation.isNil:
        return
    of Return, Revert, SelfDestruct:
      break
    else:
      discard


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
