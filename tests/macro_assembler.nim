import
  macros, macrocache, strutils, unittest,
  byteutils, chronicles, ranges, eth/common,
  ../nimbus/vm/interpreter/opcode_values,
  std_shims/macros_shim

import
  options, json, os, eth/trie/[db, hexary],
  ../nimbus/[vm_state, tracer, vm_types, transaction],
  ../nimbus/db/[db_chain, state_db],
  ../nimbus/vm_state_transactions,
  ../nimbus/vm/interpreter/[vm_forks, gas_costs],
  ../nimbus/utils/addresses,
  ../nimbus/vm/[message, computation, memory]

export opcode_values, byteutils
{.experimental: "dynamicBindSym".}

type
  VMWord* = array[32, byte]
  Storage* = tuple[key, val: VMWord]

  Assembler* = object
    title*: string
    stack*: seq[VMWord]
    memory*: seq[VMWord]
    storage*: seq[Storage]
    code*: seq[byte]
    logs*: seq[Log]
    success*: bool
    gasLimit*: GasInt
    gasUsed*: GasInt
    data*: seq[byte]
    output*: seq[byte]

const
  idToOpcode = CacheTable"NimbusMacroAssembler"

static:
  for n in Op:
    idToOpcode[$n] = newLit(ord(n))

proc validateVMWord(val: string, n: NimNode): VMWord =
  if val.len <= 2 or val.len > 66: error("invalid hex string", n)
  if not (val[0] == '0' and val[1] == 'x'): error("invalid hex string", n)
  let zerosLen = 64 - (val.len - 2)
  let value = repeat('0', zerosLen) & val.substr(2)
  hexToByteArray(value, result)

proc validateVMWord(val: NimNode): VMWord =
  val.expectKind(nnkStrLit)
  validateVMWord(val.strVal, val)

proc parseVMWords(list: NimNode): seq[VMWord] =
  result = @[]
  list.expectKind nnkStmtList
  for val in list:
    result.add validateVMWord(val)

proc validateStorage(val: NimNode): Storage =
  val.expectKind(nnkCall)
  val[0].expectKind(nnkStrLit)
  val[1].expectKind(nnkStmtList)
  assert(val[1].len == 1)
  val[1][0].expectKind(nnkStrLit)
  result = (validateVMWord(val[0]), validateVMWord(val[1][0]))

proc parseStorage(list: NimNode): seq[Storage] =
  result = @[]
  list.expectKind nnkStmtList
  for val in list:
    result.add validateStorage(val)

proc parseSuccess(list: NimNode): bool =
  list.expectKind nnkStmtList
  list[0].expectKind(nnkIdent)
  $list[0] == "true"

proc parseData(list: NimNode): seq[byte] =
  result = @[]
  list.expectKind nnkStmtList
  for n in list:
    n.expectKind(nnkStrLit)
    result.add hexToSeqByte(n.strVal)

proc parseLog(node: NimNode): Log =
  node.expectKind(nnkPar)
  for item in node:
    item.expectKind(nnkExprColonExpr)
    let label = item[0].strVal
    let body  = item[1]
    case label.normalize
    of "address":
      body.expectKind(nnkStrLit)
      let value = body.strVal
      if value.len < 20:
        error("bad address format", body)
      hexToByteArray(value, result.address)
    of "topics":
      body.expectKind(nnkBracket)
      for x in body:
        result.topics.add validateVMWord(x.strVal, x)
    of "data":
      result.data = hexToSeqByte(body.strVal)
    else:error("unknown log section '" & label & "'", item[0])

proc parseLogs(list: NimNode): seq[Log] =
  result = @[]
  list.expectKind nnkStmtList
  for n in list:
    result.add parseLog(n)

proc validateOpcode(sym: NimNode) =
  let typ = getTypeInst(sym)
  typ.expectKind(nnkSym)
  if $typ != "Op":
    error("unknown opcode '" & $sym & "'", sym)

proc addOpCode(code: var seq[byte], node, params: NimNode) =
  node.expectKind nnkSym
  let opcode = Op(idToOpcode[node.strVal].intVal)
  case opcode
  of Push1..Push32:
    if params.len != 1:
      error("expect 1 param, but got " & $params.len, node)
    let paramWidth = (opcode.ord - 95) * 2
    params[0].expectKind nnkStrLit
    var val = params[0].strVal
    if val[0] == '0' and val[1] == 'x':
      val = val.substr(2)
      if val.len != paramWidth:
        error("expected param with " & $paramWidth & " hex digits, got " & $val.len, node)
      code.add byte(opcode)
      code.add hexToSeqByte(val)
    else:
      error("invalid hex format", node)
  else:
    if params.len > 0:
      error("there should be no param for this instruction", node)
    code.add byte(opcode)

proc parseCode(codes: NimNode): seq[byte] =
  let emptyNode = newEmptyNode()
  codes.expectKind nnkStmtList
  var addStop = true
  for pc, line in codes:
    line.expectKind({nnkCommand, nnkIdent, nnkStrLit})
    if line.kind == nnkStrLit:
      result.add hexToSeqByte(line.strVal)
    elif line.kind == nnkIdent:
      let sym = bindSym(line)
      validateOpcode(sym)
      result.addOpCode(sym, emptyNode)
      if pc == codes.len - 1:
        addStop = $sym != "Stop"
    elif line.kind == nnkCommand:
      let sym = bindSym(line[0])
      validateOpcode(sym)
      var params = newNimNode(nnkBracket)
      for i in 1 ..< line.len:
        params.add line[i]
      result.addOpCode(sym, params)
    else:
      error("unknown syntax: " & line.toStrLit.strVal, line)

  if addStop:
    result.addOpCode(bindSym"Stop", emptyNode)

proc generateVMProxy(boa: Assembler): NimNode =
  let
    vmProxy = genSym(nskProc, "vmProxy")
    blockNumber = ident("blockNumber")
    chainDB = ident("chainDB")
    title = boa.title
    body = newLitFixed(boa)

  result = quote do:
    test `title`:
      proc `vmProxy`(): bool =
        let boa = `body`
        runVM(`blockNumber`, `chainDB`, boa)
      check `vmProxy`()

  when defined(macro_assembler_debug):
    echo result.toStrLit.strVal

const
  blockFile = "tests" / "fixtures" / "PersistBlockTests" / "block47205.json"

proc initComputation(vmState: BaseVMState, tx: Transaction, sender: EthAddress, data: seq[byte], forkOverride=none(Fork)) : BaseComputation =
  assert tx.isContractCreation

  let fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.blockNumber.toFork

  let gasUsed = 0 #tx.payload.intrinsicGas.GasInt + gasFees[fork][GasTXCreate]

  let contractAddress = generateAddress(sender, tx.accountNonce)
  let msg = newMessage(tx.gasLimit - gasUsed, tx.gasPrice, tx.to, sender, tx.value, data, tx.payload,
                       options = newMessageOptions(origin = sender, createAddress = contractAddress))

  newBaseComputation(vmState, vmState.blockNumber, msg, some(fork))

proc initDatabase*(): (Uint256, BaseChainDB) =
  let
    node = json.parseFile(blockFile)
    blockNumber = UInt256.fromHex(node["blockNumber"].getStr())
    memoryDB = newMemoryDB()
    state = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

  result = (blockNumber, newBaseChainDB(memoryDB, false))

proc initComputation(blockNumber: Uint256, chainDB: BaseChainDB, payload, data: seq[byte]): BaseComputation =
  let
    parentNumber = blockNumber - 1
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = chainDB.getBlockBody(headerHash)
    vmState = newBaseVMState(parent, chainDB)

  var
    tx = body.transactions[0]
    sender = tracer.getSender(tx)

  tx.payload = payload
  tx.gasLimit = 500000000
  initComputation(vmState, tx, sender, data, none(Fork))

proc runVM*(blockNumber: Uint256, chainDB: BaseChainDB, boa: Assembler): bool =
  var computation = initComputation(blockNumber, chainDB, boa.code, boa.data)

  let gas = computation.gasMeter.gasRemaining
  let computationResult = execComputation(computation)
  let gasUsed = gas - computation.gasMeter.gasRemaining

  if computationResult:
    if boa.success == false:
      error "different success value", expected=boa.success, actual=true
      return false
  else:
    if boa.success == true:
      error "different success value", expected=boa.success, actual=false
      return false

  if boa.stack.len != computation.stack.values.len:
    error "different stack len", expected=boa.stack.len, actual=computation.stack.values.len
    return false

  for i, v in computation.stack.values:
    let actual = v.dumpHex()
    let val = boa.stack[i].toHex()
    if actual != val:
      error "different stack value", idx=i, expected=val, actual=actual
      return false

  const chunkLen = 32
  let numChunks = computation.memory.len div chunkLen

  if numChunks != boa.memory.len:
    error "different memory len", expected=boa.memory.len, actual=numChunks
    return false

  for i in 0 ..< numChunks:
    let actual = computation.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex()
    let mem = boa.memory[i].toHex()
    if mem != actual:
      error "different memory value", idx=i, expected=mem, actual=actual
      return false

  var
    stateDB = computation.vmState.accountDb
    account = stateDB.getAccount(computation.msg.storageAddress)
    trie = initSecureHexaryTrie(chainDB.db, account.storageRoot)

  for kv in boa.storage:
    let key = kv[0].toHex()
    let val = kv[1].toHex()
    let keyBytes = (@(kv[0])).toRange
    let actual = trie.get(keyBytes).toOpenArray().toHex()
    let zerosLen = 64 - (actual.len)
    let value = repeat('0', zerosLen) & actual
    if val != value:
      error "storage has different value", key=key, expected=val, actual=value
      return false

  let logs = computation.vmState.logEntries
  if logs.len != boa.logs.len:
    error "different logs len", expected=boa.logs.len, actual=logs.len
    return false

  for i, log in boa.logs:
    let eAddr = log.address.toHex()
    let aAddr = logs[i].address.toHex()
    if eAddr != aAddr:
      error "different address", expected=eAddr, actual=aAddr, idx=i
      return false
    let eData = log.data.toHex()
    let aData = logs[i].data.toHex()
    if eData != aData:
      error "different data", expected=eData, actual=aData, idx=i
      return false
    if log.topics.len != logs[i].topics.len:
      error "different topics len", expected=log.topics.len, actual=logs[i].topics.len, idx=i
      return false
    for x, t in log.topics:
      let eTopic = t.toHex()
      let aTopic = logs[i].topics[x].toHex()
      if eTopic != aTopic:
        error "different topic in log entry", expected=eTopic, actual=aTopic, logIdx=i, topicIdx=x
        return false

  if boa.output.len > 0:
    let actual = computation.output.toHex()
    let expected = boa.output.toHex()
    if expected != actual:
      error "different output detected", expected=expected, actual=actual
      return false

  result = true

macro assembler*(list: untyped): untyped =
  var boa = Assembler(success: true)
  list.expectKind nnkStmtList
  for callSection in list:
    callSection.expectKind(nnkCall)
    let label = callSection[0].strVal
    let body  = callSection[1]
    case label.normalize
    of "title":
      let title = body[0]
      title.expectKind(nnkStrLit)
      boa.title = title.strVal
    of "code"  : boa.code = parseCode(body)
    of "memory": boa.memory = parseVMWords(body)
    of "stack" : boa.stack = parseVMWords(body)
    of "storage": boa.storage = parseStorage(body)
    of "logs": boa.logs = parseLogs(body)
    of "success": boa.success = parseSuccess(body)
    of "data": boa.data = parseData(body)
    of "output": boa.output = parseData(body)
    else: error("unknown section '" & label & "'", callSection[0])
  result = boa.generateVMProxy()
