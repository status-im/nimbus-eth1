import
  json, strutils,
  eth_common, stint, byteutils,
  ../vm_types, memory, stack

proc initTrace(t: var TransactionTracer) =
  t.trace = newJObject()
  t.trace["structLogs"] = newJArray()

proc traceOpCodeStarted*(t: var TransactionTracer, c: BaseComputation, op: string) =
  if unlikely t.trace.isNil:
    t.initTrace()

  let j = newJObject()
  t.trace["structLogs"].add(j)

  j["op"] = %op.toUpperAscii
  j["pc"] = %(c.code.pc - 1)
  j["depth"] = %1 # stub
  j["gas"] = %c.gasMeter.gasRemaining
  t.gasRemaining = c.gasMeter.gasRemaining

  # log stack
  let st = newJArray()
  for v in c.stack.values:
    st.add(%v.dumpHex())
  j["stack"] = st
  # log memory
  let mem = newJArray()
  const chunkLen = 32
  let numChunks = c.memory.len div chunkLen
  for i in 0 ..< numChunks:
    mem.add(%c.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex())
  j["memory"] = mem
  # TODO: log storage

proc traceOpCodeEnded*(t: var TransactionTracer, c: BaseComputation) =
  let j = t.trace["structLogs"].elems[^1]
  j["gasCost"] = %(t.gasRemaining - c.gasMeter.gasRemaining)

