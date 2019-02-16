import
  json, strutils, sets, hashes,
  chronicles, nimcrypto, eth/common, stint,
  ../vm_types, memory, stack, ../db/[db_chain, state_db],
  eth/trie/hexary, ./message, ranges/typedranges,
  ./interpreter/opcode_values

logScope:
  topics = "vm opcode"

proc hash*(x: Uint256): Hash =
  result = hash(x.toByteArrayBE)

proc initTracer*(tracer: var TransactionTracer, flags: set[TracerFlags] = {}) =
  tracer.trace = newJObject()

  # make appear at the top of json object
  tracer.trace["gas"] = %0
  tracer.trace["failed"] = %false
  tracer.trace["returnValue"] = %""

  tracer.trace["structLogs"] = newJArray()
  tracer.flags = flags
  tracer.accounts = initSet[EthAddress]()
  tracer.storageKeys = @[]

proc rememberStorageKey(tracer: var TransactionTracer, compDepth: int, key: Uint256) =
  assert compDepth >= 0 and compDepth <= tracer.storageKeys.len
  if compDepth == tracer.storageKeys.len:
    tracer.storageKeys.setLen(compDepth + 1)
    tracer.storageKeys[compDepth] = initSet[Uint256]()

  tracer.storageKeys[compDepth].incl key

iterator storage(tracer: TransactionTracer, compDepth: int): Uint256 =
  assert compDepth >= 0 and compDepth < tracer.storageKeys.len
  for key in tracer.storageKeys[compDepth]:
    yield key

proc traceOpCodeStarted*(tracer: var TransactionTracer, c: BaseComputation, op: Op) =
  if unlikely tracer.trace.isNil:
    tracer.initTracer()

  let j = newJObject()
  tracer.trace["structLogs"].add(j)

  j["op"] = %(($op).toUpperAscii)
  j["pc"] = %(c.code.pc - 1)
  j["depth"] = %(c.msg.depth + 1)
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

  if TracerFlags.EnableAccount in tracer.flags:
    case op
    of Call, CallCode, DelegateCall, StaticCall:
      assert(c.stack.values.len > 2)
      tracer.accounts.incl c.stack[^2, EthAddress]
    of ExtCodeCopy, ExtCodeSize, Balance, SelfDestruct:
      assert(c.stack.values.len > 1)
      tracer.accounts.incl c.stack[^1, EthAddress]
    else:
      discard

  if TracerFlags.DisableStorage notin tracer.flags:
    if op == Sstore:
      assert(c.stack.values.len > 1)
      tracer.rememberStorageKey(c.msg.depth, c.stack[^1, Uint256])

proc traceOpCodeEnded*(tracer: var TransactionTracer, c: BaseComputation, op: Op) =
  let j = tracer.trace["structLogs"].elems[^1]

  # TODO: figure out how to get storage
  # when contract execution interrupted by exception
  if TracerFlags.DisableStorage notin tracer.flags:
    var storage = newJObject()
    if c.msg.depth < tracer.storageKeys.len:
      var stateDB = c.vmState.accountDb
      for key in tracer.storage(c.msg.depth):
        let (value, _) = stateDB.getStorage(c.msg.storageAddress, key)
        storage[key.dumpHex] = %(value.dumpHex)
      j["storage"] = storage

  j["gasCost"] = %(tracer.gasRemaining - c.gasMeter.gasRemaining)

  if op in {Return, Revert}:
    let returnValue = %("0x" & toHex(c.rawOutput, true))
    j["returnValue"] = returnValue
    tracer.trace["returnValue"] = returnValue

  trace "Op", json = j.pretty()

proc traceError*(tracer: var TransactionTracer, c: BaseComputation) =
  let j = tracer.trace["structLogs"].elems[^1]

  # TODO: figure out how to get gasCost
  # when contract execution failed before traceOpCodeEnded called
  # because exception raised
  #j["gasCost"] = %

  j["error"] = %(c.error.info)
  tracer.trace["failed"] = %true

  trace "Error", json = j.pretty()
