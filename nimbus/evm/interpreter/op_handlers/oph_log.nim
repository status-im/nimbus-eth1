# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## EVM Opcode Handlers: Logging Operations
## =======================================
##

import
  ../../../constants,
  ../../../errors,
  ../../computation,
  ../../memory,
  ../../stack,
  ../../types,
  ../gas_costs,
  ../gas_meter,
  ../op_codes,
  ../utils/utils_numeric,
  ./oph_defs,
  ./oph_gen_handlers,
  ./oph_helpers,
  eth/common,
  sequtils,
  stint,
  strformat

{.push raises: [CatchableError].} # basically the annotation type of a `Vm2OpFn`

# ------------------------------------------------------------------------------
# Private, names & settings
# ------------------------------------------------------------------------------

proc fnName(n: int): string {.compileTime.} =
  &"log{n}Op"

proc opName(n: int): string {.compileTime.} =
  &"Log{n}"

proc fnInfo(n: int): string {.compileTime.} =
  var blurb = case n
              of 1: "topic"
              else: "topics"
  &"Append log record with {n} {blurb}"


proc logImpl(c: Computation, opcode: Op, topicCount: int) =
  doAssert(topicCount in 0 .. 4)
  checkInStaticContext(c)
  let (memStartPosition, size) = c.stack.popInt(2)
  let (memPos, len) = (memStartPosition.cleanMemRef, size.cleanMemRef)

  if memPos < 0 or len < 0:
    raise newException(OutOfBoundsRead, "Out of bounds memory access")

  c.gasMeter.consumeGas(
    c.gasCosts[opcode].m_handler(c.memory.len, memPos, len),
    reason = "Memory expansion, Log topic and data gas cost")
  c.memory.extend(memPos, len)

  when evmc_enabled:
    var topics: array[4, evmc_bytes32]
    for i in 0 ..< topicCount:
      topics[i].bytes = c.stack.popTopic()

    c.host.emitLog(c.msg.contractAddress,
      c.memory.read(memPos, len),
      topics[0].addr, topicCount)
  else:
    var log: Log
    log.topics = newSeqOfCap[Topic](topicCount)
    for i in 0 ..< topicCount:
      log.topics.add(c.stack.popTopic())

    log.data = c.memory.read(memPos, len)
    log.address = c.msg.contractAddress
    c.addLogEntry(log)

const
  inxRange = toSeq(0 .. 4)
  logOpArg = block:
    var rc: array[inxRange.len + 1, Op]
    for n in inxRange:
      rc[n] = Op(Log0.int + n)
    rc

# ------------------------------------------------------------------------------
# Private, op handlers implementation
# ------------------------------------------------------------------------------

proc wrapperFn(k: var Vm2Ctx; n: int) =
  logImpl(k.cpt, logOpArg[n], n)

genOphHandlers fnName, fnInfo, inxRange, wrapperFn

# ------------------------------------------------------------------------------
# Public, op exec table entries
# ------------------------------------------------------------------------------

genOphList fnName, fnInfo, inxRange, "vm2OpExecLog", opName

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
