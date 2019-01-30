import
  macros, strutils, unittest, byteutils, chronicles,
  ../nimbus/vm/interpreter/opcode_values, ranges, eth_common

import
  options, json, os, eth_trie/[db, hexary],
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

  OpcodeDesc = object
    numParams: int

var
  g_asm {.compileTime.}: Assembler
  g_code {.compileTime.}: NimNode
  g_lookup {.compileTime.}: array[256, OpcodeDesc]

proc writeLUT(opcode: Op, numParams: int) {.compileTime.} =
  g_lookup[ord(opcode)] = OpcodeDesc(numParams: numParams)

proc initializeLUT() {.compileTime.} =
  writeLUT(Stop, 0)
  writeLUT(Add, 2)
  writeLUT(Mul, 2)
  writeLUT(Sub, 2)
  writeLUT(Div, 2)
  writeLUT(Sdiv, 2)
  writeLUT(Mod, 2)
  writeLUT(Smod, 2)
  writeLUT(Addmod, 3)
  writeLUT(Mulmod, 3)
  writeLUT(Exp, 2)
  writeLUT(SignExtend, 2)

  writeLUT(Lt, 2)
  writeLUT(Gt, 2)
  writeLUT(Slt, 2)
  writeLUT(Sgt, 2)
  writeLUT(Eq, 2)
  writeLUT(IsZero, 1)
  writeLUT(And, 2)
  writeLUT(Or, 2)
  writeLUT(Xor, 2)
  writeLUT(Not, 1)
  writeLUT(Byte, 2)

  writeLUT(Sha3, 2)

  writeLUT(Address, 0)
  writeLUT(Balance, 1)
  writeLUT(Origin, 0)
  writeLUT(Caller, 0)
  writeLUT(CallValue, 0)
  writeLUT(CallDataLoad, 1)
  writeLUT(CallDataSize, 0)
  writeLUT(CallDataCopy, 3)
  writeLUT(CodeSize, 0)
  writeLUT(CodeCopy, 3)
  writeLUT(GasPrice, 0)
  writeLUT(ExtCodeSize, 1)
  writeLUT(ExtCodeCopy, 4)
  writeLUT(ReturnDataSize, 0)
  writeLUT(ReturnDataCopy, 3)

  writeLUT(Blockhash, 1)
  writeLUT(Coinbase, 0)
  writeLUT(Timestamp, 0)
  writeLUT(Number, 0)
  writeLUT(Difficulty, 0)
  writeLUT(GasLimit, 0)

  writeLUT(Pop, 1)
  writeLUT(Mload, 1)
  writeLUT(Mstore, 2)
  writeLUT(Mstore8, 2)
  writeLUT(Sload, 1)
  writeLUT(Sstore, 2)
  writeLUT(Jump, 1)
  writeLUT(JumpI, 2)
  writeLUT(Pc, 0)
  writeLUT(Msize, 0)
  writeLUT(Gas, 0)
  writeLUT(JumpDest, 0)

  for i in Push1 .. Push32:
    writeLUT(i, 1)

  for i in Dup1 .. Dup16:
    writeLUT(i, 0)

  for i in Swap1 .. Swap16:
    writeLUT(i, 0)

  for i in Log0 .. Log4:
    writeLUT(i, 0)

  writeLUT(Create, 3)
  writeLUT(Call, 7)
  writeLUT(CallCode, 7)
  writeLUT(Return, 2)
  writeLUT(DelegateCall, 6)
  writeLUT(StaticCall, 6)
  writeLUT(Revert, 2)
  writeLUT(Invalid, 1)
  writeLUT(SelfDestruct, 1)

static:
  initializeLUT()

proc validateVMWord(val: string, n: NimNode): VMWord =
  if val.len <= 2 or val.len > 66:
    error("invalid hex string", n)
  if not (val[0] == '0' and val[1] == 'x'):
    error("invalid hex string", n)
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

proc validateOpcode(sym: NimNode) =
  let typ = getTypeInst(sym)
  typ.expectKind(nnkSym)
  if $typ != "Op":
    error("unknown opcode '" & $sym & "'", sym)

proc addOpCode(opcode: Op, node: NimNode, params: varargs[string]) =
  let lut = g_lookup[opcode.ord]
  if lut.numParams > 0 and params.len > 0:
    if lut.numParams != params.len:
      error("Opcode '" & $opcode & "' expect " & $lut.numParams & " params, but got " & $params.len, node)
  case opcode
  of Push1..Push32:
    if params.len != 1:
      error("expect 1 param, but got " & $params.len, node)
    let paramWidth = (opcode.ord - 95) * 2
    var val = params[0]
    if val[0] == '0' and val[1] == 'x':
      val = val.substr(2)
      if val.len != paramWidth:
        error("expected param with " & $paramWidth & " hex digits, got " & $val.len, node)
      g_asm.code.add byte(opcode)
      g_asm.code.add hexToSeqByte(val)
    else:
      error("invalid hex format", node)
  else:
    if params.len > 0:
      for i in countDown(params.len - 1, 0):
        g_asm.code.add byte(Push32)
        g_asm.code.add validateVMWord(params[i], node)
    g_asm.code.add byte(opcode)

proc addLiteral(node: NimNode, rawCode: string) =
  if rawCode[0] == '0' and rawCode[1] == 'x':
    let val = rawCode.substr(2)
    g_asm.code.add hexToSeqByte(val)
  else:
    error("invalid hex format", node)

proc generateVMProxy(boa: Assembler): NimNode =
  let vmProxy = genSym(nskProc, "vmProxy")
  var body = newStmtList()
  let
    boaIdent = ident("boa")
    title = boa.title
    success = ident(if boa.success: "true" else: "false")
    code = boa.code.toHex()
    blockNumber = ident("blockNumber")
    chainDB = ident("chainDB")
    gasLimit = boa.gasLimit
    gasUsed = boa.gasUsed
    data = boa.data.toHex()
    output = boa.output.toHex()

  body.add quote do:
    var `boaIdent`: Assembler
    `boaIdent`.success = `success`
    `boaIdent`.code = hexToSeqByte(`code`)
    `boaIdent`.title = `title`
    `boaIdent`.gasLimit = `gasLimit`
    `boaIdent`.gasUsed = `gasUsed`

  if boa.data.len > 0:
    body.add quote do:
      `boaIdent`.data = hexToSeqByte(`data`)

  if boa.output.len > 0:
    body.add quote do:
      `boaIdent`.output = hexToSeqByte(`output`)

  if boa.stack.len > 0:
    let len = boa.stack.len
    body.add quote do:
      `boaIdent`.stack = newSeq[VMWord](`len`)

  if boa.memory.len > 0:
    let len = boa.memory.len
    body.add quote do:
      `boaIdent`.memory = newSeq[VMWord](`len`)

  if boa.storage.len > 0:
    let len = boa.storage.len
    body.add quote do:
      `boaIdent`.storage = newSeq[Storage](`len`)

  for i, s in boa.stack:
    let val = s.toHex()
    body.add quote do:
      hexToByteArray(`val`, `boaIdent`.stack[`i`])

  for i, s in boa.memory:
    let val = s.toHex()
    body.add quote do:
      hexToByteArray(`val`, `boaIdent`.memory[`i`])

  for i, kv in boa.storage:
    let key = kv[0].toHex()
    let val = kv[1].toHex()
    body.add quote do:
      hexToByteArray(`key`, `boaIdent`.storage[`i`].key)
      hexToByteArray(`val`, `boaIdent`.storage[`i`].val)

  if boa.logs.len > 0:
    let len = boa.logs.len
    body.add quote do:
      `boaIdent`.logs = newSeq[Log](`len`)

  for i, log in boa.logs:
    let address = log.address.toHex()
    let data = log.data.toHex()
    body.add quote do:
      hexToByteArray(`address`, `boaIdent`.logs[`i`].address)
      `boaIdent`.logs[`i`].data = hexToSeqByte(`data`)
    if log.topics.len > 0:
      let len = log.topics.len
      body.add quote do:
        `boaIdent`.logs[`i`].topics = newSeq[Topic](`len`)
    for x, t in log.topics:
      let topic = t.toHex()
      body.add quote do:
        hexToByteArray(`topic`, `boaIdent`.logs[`i`].topics[`x`])

  body.add quote do: runVM(`blockNumber`, `chainDB`, `boaIdent`)

  result = quote do:
    test `title`:
      proc `vmProxy`(): bool =
        `body`
      check `vmProxy`()

  when defined(macro_assembler_debug):
    echo result.toStrLit.strVal

proc assemblerImpl(boa: var Assembler, codes: NimNode): NimNode =
  g_code = codes
  boa.code = @[]
  codes.expectKind nnkStmtList
  let macroName = genSym(nskMacro, "asmProxy")
  var addStop = true
  var body = newStmtList()
  for pc, line in codes:
    line.expectKind({nnkCommand, nnkIdent, nnkStrLit})
    if line.kind == nnkStrLit:
      body.add quote do:
        addLiteral(g_code[`pc`], `line`)
    elif line.kind == nnkIdent:
      let sym = bindSym(line)
      validateOpcode(sym)
      body.add quote do:
        addOpCode(`sym`, g_code[`pc`])
      if pc == codes.len - 1:
        if normalize($sym) == "stop":
          addStop = false
    elif line.kind == nnkCommand:
      let ident = line[0]
      let sym = bindSym(ident)
      validateOpcode(sym)
      var params = newNimNode(nnkBracket)
      for i in 1 ..< line.len:
        params.add line[i]
      body.add quote do:
        addOpCode(`sym`, g_code[`pc`], `params`)
    else:
      error("unknown syntax: " & line.toStrLit.strVal, line)

  let stop = ident("Stop")
  if addStop:
    body.add quote do:
      addOpCode(`stop`, newEmptyNode())

  let resIdent = ident("result")

  result = quote do:
    macro `macroName`(): untyped =
      `body`
      `resIdent` = generateVMProxy(g_asm)
    `macroName`()

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

macro assembler*(list: untyped): untyped =
  var boa: Assembler
  boa.success = true
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
    of "code"  : result = assemblerImpl(boa, body)
    of "memory": boa.memory = parseVMWords(body)
    of "stack" : boa.stack = parseVMWords(body)
    of "storage": boa.storage = parseStorage(body)
    of "logs": boa.logs = parseLogs(body)
    of "success": boa.success = parseSuccess(body)
    of "data": boa.data = parseData(body)
    of "output": boa.output = parseData(body)
    else: error("unknown section '" & label & "'", callSection[0])
  g_asm = boa
