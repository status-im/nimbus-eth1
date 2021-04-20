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


const
  kludge {.intdefine.}: int = 0
  breakCircularDependency {.used.} = kludge > 0

import
  ../../../errors,
  ./oph_defs,
  ./oph_helpers,
  sequtils,
  eth/common,
  strformat,
  stint

# ------------------------------------------------------------------------------
# Kludge BEGIN
# ------------------------------------------------------------------------------

when not breakCircularDependency:
  import
    ../../../constants,
    ../../stack,
    ../../v2computation,
    ../../v2memory,
    ../../v2types,
    ../gas_meter,
    ../utils/v2utils_numeric,
    ../v2gas_costs,
    eth/common

else:
  import
    macros

  var blindGasCosts: array[Op,int]
  var blindTopic: Topic

  # copied from stack.nim
  macro genTupleType(len: static[int], elemType: untyped): untyped =
    result = nnkTupleConstr.newNimNode()
    for i in 0 ..< len: result.add(elemType)

  # function stubs from stack.nim (to satisfy compiler logic)
  proc popTopic(x: var Stack): Topic = blindTopic
  proc popInt(x: var Stack, n: static[int]): auto =
    var rc: genTupleType(n, UInt256)
    return rc

  # function stubs from v2computation.nim (to satisfy compiler logic)
  proc gasCosts(c: Computation): array[Op,int] = blindGasCosts
  proc addLogEntry(c: Computation, log: Log) = discard

  # function stubs from v2utils_numeric.nim
  func cleanMemRef(x: UInt256): int = 0

  # function stubs from v2memory.nim
  proc len(mem: Memory): int = 0
  proc extend(mem: var Memory; startPos: Natural; size: Natural) = discard
  proc read(mem: var Memory, startPos: Natural, size: Natural): seq[byte] = @[]

  # function stubs from gas_meter.nim
  proc consumeGas(gasMeter: var GasMeter; amount: int; reason: string) = discard

  # stubs from v2gas_costs.nim
  proc m_handler(x: int; curMemSize, memOffset, memLen: int64): int = 0

# ------------------------------------------------------------------------------
# Kludge END
# ------------------------------------------------------------------------------

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
