# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils, sets, hashes],
  chronicles, eth/common, stint,
  nimcrypto/utils,
  ../utils/functors/possible_futures,
  ./types, ./memory, ./stack, ../db/accounts_cache,
  ./interpreter/op_codes

logScope:
  topics = "vm opcode"

proc hash*(x: UInt256): Hash =
  result = hash(x.toByteArrayBE)

proc initTracer*(tracer: var TransactionTracer, flags: set[TracerFlags] = {}) =
  tracer.trace = newJObject()

  # make appear at the top of json object
  tracer.trace["gas"] = %0
  tracer.trace["failed"] = %false

  if TracerFlags.GethCompatibility in tracer.flags:
    tracer.trace["returnData"] = %""
  else:
    tracer.trace["returnValue"] = %""

  tracer.trace["structLogs"] = newJArray()
  tracer.flags = flags
  tracer.accounts = initHashSet[EthAddress]()
  tracer.storageKeys = @[]

proc prepare*(tracer: var TransactionTracer, compDepth: int) =
  # this uncommon arragement is intentional
  # compDepth will be varying up and down: 1,2,3,4,3,3,2,2,1
  # see issue #245 and PR #247 discussion
  if compDepth >= tracer.storageKeys.len:
    let prevLen = tracer.storageKeys.len
    tracer.storageKeys.setLen(compDepth + 1)
    for i in prevLen ..< tracer.storageKeys.len - 1:
      tracer.storageKeys[i] = initHashSet[UInt256]()

  tracer.storageKeys[compDepth] = initHashSet[UInt256]()

proc rememberStorageKey(tracer: var TransactionTracer, compDepth: int, key: UInt256) =
  tracer.storageKeys[compDepth].incl key

iterator storage(tracer: TransactionTracer, compDepth: int): UInt256 =
  doAssert compDepth >= 0 and compDepth < tracer.storageKeys.len
  for key in tracer.storageKeys[compDepth]:
    yield key

template stripLeadingZeros(value: string): string =
  var cidx = 0
  # ignore the last character so we retain '0' on zero value
  while cidx < value.len - 1 and value[cidx] == '0':
    cidx.inc
  value[cidx .. ^1]

proc encodeHexInt(x: SomeInteger): JsonNode =
  %("0x" & x.toHex.stripLeadingZeros.toLowerAscii)

proc traceOpCodeStarted*(tracer: var TransactionTracer, c: Computation, op: Op): int =
  if unlikely tracer.trace.isNil:
    tracer.initTracer()

  let j = newJObject()
  tracer.trace["structLogs"].add(j)

  if TracerFlags.GethCompatibility in tracer.flags:
    j["pc"] = %(c.code.pc - 1)
    j["op"] = %(op.int)
    j["gas"] = encodeHexInt(c.gasMeter.gasRemaining)
    j["gasCost"] = %("")
    j["memSize"] = %c.memory.len
    j["opName"] = %(($op).toUpperAscii)
    j["depth"] = %(c.msg.depth + 1)

    # log stack
    if TracerFlags.DisableStack notin tracer.flags:
      let st = newJArray()
      for v in c.stack.values:
        st.add(%("0x" & v.dumpHex.stripLeadingZeros))
      j["stack"] = st

  else:
    j["op"] = %(($op).toUpperAscii)
    j["pc"] = %(c.code.pc - 1)
    j["depth"] = %(c.msg.depth + 1)
    j["gas"] = %c.gasMeter.gasRemaining

    # log stack
    if TracerFlags.DisableStack notin tracer.flags:
      let st = newJArray()
      for v in c.stack.values:
        st.add(%v.dumpHex())
      j["stack"] = st

  # log memory
  if TracerFlags.DisableMemory notin tracer.flags:
    let bytes = c.memory.waitForBytes  # FIXME-Adam: it's either this or make the tracer async; ugh.
    let mem = newJArray()
    const chunkLen = 32
    let numChunks = c.memory.len div chunkLen
    for i in 0 ..< numChunks:
      let memHex = bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex()
      if TracerFlags.GethCompatibility in tracer.flags:
        mem.add(%("0x" & memHex.toLowerAscii))
      else:
        mem.add(%memHex)
    j["memory"] = mem

  if TracerFlags.EnableAccount in tracer.flags:
    case op
    of Call, CallCode, DelegateCall, StaticCall:
      if c.stack.values.len > 2:
        tracer.accounts.incl c.stack[^2, EthAddress]
    of ExtCodeCopy, ExtCodeSize, Balance, SelfDestruct:
      if c.stack.values.len > 1:
        tracer.accounts.incl c.stack[^1, EthAddress]
    else:
      discard

  if TracerFlags.DisableStorage notin tracer.flags:
    if op == Sstore:
      if c.stack.values.len > 1:
        tracer.rememberStorageKey(c.msg.depth, c.stack[^1, UInt256])

  result = tracer.trace["structLogs"].len - 1

proc traceOpCodeEnded*(tracer: var TransactionTracer, c: Computation, op: Op, lastIndex: int) =
  let j = tracer.trace["structLogs"].elems[lastIndex]

  # TODO: figure out how to get storage
  # when contract execution interrupted by exception
  if TracerFlags.DisableStorage notin tracer.flags:
    var storage = newJObject()
    if c.msg.depth < tracer.storageKeys.len:
      var stateDB = c.vmState.stateDB
      for key in tracer.storage(c.msg.depth):
        let value = waitForValueOf(stateDB.getStorageCell(c.msg.contractAddress, key)) # FIXME-Adam: again, I don't like the waitFor
        if TracerFlags.GethCompatibility in tracer.flags:
          storage["0x" & key.dumpHex.stripLeadingZeros] =
            %("0x" & value.dumpHex.stripLeadingZeros)
        else:
          storage[key.dumpHex] = %(value.dumpHex)
      j["storage"] = storage

  if TracerFlags.GethCompatibility in tracer.flags:
    let gas = fromHex[GasInt](j["gas"].getStr)
    j["gasCost"] = encodeHexInt(gas - c.gasMeter.gasRemaining)
  else:
    let gas = j["gas"].getBiggestInt()
    j["gasCost"] = %(gas - c.gasMeter.gasRemaining)

  if op in {Return, Revert} and TracerFlags.DisableReturnData notin tracer.flags:
    let returnValue = %("0x" & toHex(c.output, true))
    if TracerFlags.GethCompatibility in tracer.flags:
      j["returnData"] = returnValue
      tracer.trace["returnData"] = returnValue
    else:
      j["returnValue"] = returnValue
      tracer.trace["returnValue"] = returnValue

  trace "Op", json = j.pretty()

proc traceError*(tracer: var TransactionTracer, c: Computation) =
  if tracer.trace["structLogs"].elems.len > 0:
    let j = tracer.trace["structLogs"].elems[^1]
    j["error"] = %(c.error.info)
    trace "Error", json = j.pretty()

    # even though the gasCost is incorrect,
    # we have something to display,
    # it is an error anyway
    if TracerFlags.GethCompatibility in tracer.flags:
      let gas = fromHex[GasInt](j["gas"].getStr)
      j["gasCost"] = encodeHexInt(gas - c.gasMeter.gasRemaining)
    else:
      let gas = j["gas"].getBiggestInt()
      j["gasCost"] = %(gas - c.gasMeter.gasRemaining)

  tracer.trace["failed"] = %true
