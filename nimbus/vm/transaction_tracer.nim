import
  json, strutils,
  eth_common, stint, byteutils,
  ../vm_types, memory, stack,
  ../db/[db_chain, state_db],
  eth_trie/hexary, ./message,
  ranges/typedranges

proc initTracer*(tracer: var TransactionTracer, flags: set[TracerFlags] = {}) =
  tracer.trace = newJObject()

  # make appear at the top of json object
  tracer.trace["gas"] = %0
  tracer.trace["failed"] = %false
  tracer.trace["returnValue"] = %""

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

  # TODO: this seems very inefficient
  # could we improve it?
  # TODO: figure out how to get storage
  # when contract excecution interrupted by exception
  if TracerFlags.DisableStorage notin tracer.flags:
    var storage = newJObject()
    var stateDB = c.vmState.chaindb.getStateDb(c.vmState.blockHeader.stateRoot, readOnly = true)
    let storageRoot = stateDB.getStorageRoot(c.msg.storageAddress)
    var trie = initHexaryTrie(c.vmState.chaindb.db, storageRoot)
    for k, v in trie:
      var key = k.toOpenArray.toHex
      if key.len != 0:
        storage[key] = %(v.toOpenArray.toHex)
    j["storage"] = storage

proc traceOpCodeEnded*(tracer: var TransactionTracer, c: BaseComputation) =
  let j = tracer.trace["structLogs"].elems[^1]
  j["gasCost"] = %(tracer.gasRemaining - c.gasMeter.gasRemaining)

proc traceError*(tracer: var TransactionTracer, c: BaseComputation) =
  let j = tracer.trace["structLogs"].elems[^1]

  # TODO: figure out how to get gasCost
  # when contract execution failed before traceOpCodeEnded called
  # because exception raised
  #j["gasCost"] = %

  j["error"] = %(c.error.info)
  tracer.trace["failed"] = %true
