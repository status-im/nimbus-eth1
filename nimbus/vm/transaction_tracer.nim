import
  json, strutils, sets, hashes,
  chronicles, nimcrypto, eth/common, stint,
  ../vm_types, memory, stack, ../db/accounts_cache,
  eth/trie/hexary,
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
      tracer.storageKeys[i] = initHashSet[Uint256]()

  tracer.storageKeys[compDepth] = initHashSet[Uint256]()

proc rememberStorageKey(tracer: var TransactionTracer, compDepth: int, key: Uint256) =
  tracer.storageKeys[compDepth].incl key

iterator storage(tracer: TransactionTracer, compDepth: int): Uint256 =
  doAssert compDepth >= 0 and compDepth < tracer.storageKeys.len
  for key in tracer.storageKeys[compDepth]:
    yield key

proc traceOpCodeStarted*(tracer: var TransactionTracer, c: Computation, op: Op): int =
  if unlikely tracer.trace.isNil:
    tracer.initTracer()

  let j = newJObject()
  tracer.trace["structLogs"].add(j)

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
    let mem = newJArray()
    const chunkLen = 32
    let numChunks = c.memory.len div chunkLen
    for i in 0 ..< numChunks:
      mem.add(%c.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex())
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
        tracer.rememberStorageKey(c.msg.depth, c.stack[^1, Uint256])

  result = tracer.trace["structLogs"].len - 1

proc traceOpCodeEnded*(tracer: var TransactionTracer, c: Computation, op: Op, lastIndex: int) =
  let j = tracer.trace["structLogs"].elems[lastIndex]

  # TODO: figure out how to get storage
  # when contract execution interrupted by exception
  if TracerFlags.DisableStorage notin tracer.flags:
    var storage = newJObject()
    if c.msg.depth < tracer.storageKeys.len:
      var stateDB = c.vmState.accountDb
      for key in tracer.storage(c.msg.depth):
        let value = stateDB.getStorage(c.msg.contractAddress, key)
        storage[key.dumpHex] = %(value.dumpHex)
      j["storage"] = storage

  let gasRemaining = j["gas"].getBiggestInt()
  j["gasCost"] = %(gasRemaining - c.gasMeter.gasRemaining)

  if op in {Return, Revert}:
    let returnValue = %("0x" & toHex(c.output, true))
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
    let gasRemaining = j["gas"].getBiggestInt()
    j["gasCost"] = %(gasRemaining - c.gasMeter.gasRemaining)

  tracer.trace["failed"] = %true
