import
  json, strutils,
  eth_common, stint, byteutils,
  ../vm_types, memory, stack

proc initTracer*(tracer: var TransactionTracer, flags: set[TracerFlags] = {}) =
  tracer.trace = newJObject()
  tracer.trace["structLogs"] = newJArray()
  tracer.flags = flags

proc traceOpCodeStarted*(tracer: var TransactionTracer, c: BaseComputation, op: string) =
  if unlikely tracer.trace.isNil:
    tracer.initTracer()

  let j = newJObject()
  tracer.trace["structLogs"].add(j)

  j["op"] = %op.toUpperAscii
  j["pc"] = %(c.code.pc - 1)
  j["depth"] = %1 # stub
  j["gas"] = %c.gasMeter.gasRemaining
  tracer.gasRemaining = c.gasMeter.gasRemaining

  # log stack
  if TracerFlags.DisableStack notin tracer.flags:
    let st = newJArray()
    for v in c.stack.values:
      st.add(%v.dumpHex())
    j["stack"] = st

  # log memory
  if TracerFlags.DisableMemory notin tracer.flags:
    let mem = newJArray()
    const chunkLen = 32
    let numChunks = c.memory.len div chunkLen
    for i in 0 ..< numChunks:
      mem.add(%c.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex())
    j["memory"] = mem

  # TODO: log storage
  if TracerFlags.DisableStorage notin tracer.flags:
    let storage = newJArray()
    j["storage"] = storage

proc traceOpCodeEnded*(tracer: var TransactionTracer, c: BaseComputation) =
  let j = tracer.trace["structLogs"].elems[^1]
  j["gasCost"] = %(tracer.gasRemaining - c.gasMeter.gasRemaining)
