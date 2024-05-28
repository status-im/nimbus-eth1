# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[macrocache, strutils],
  eth/keys,
  unittest2,
  chronicles,
  stew/byteutils,
  stew/shims/macros

import
  ../nimbus/db/[ledger, distinct_tries],
  ../nimbus/evm/types,
  ../nimbus/vm_internals,
  ../nimbus/transaction/[call_common, call_evm],
  ../nimbus/[vm_types, vm_state],
  ../nimbus/core/pow/difficulty

# Ditto, for GasPrice.
import ../nimbus/transaction except GasPrice
import ../tools/common/helpers except LogLevel

export byteutils
{.experimental: "dynamicBindSym".}

# backported from Nim 0.19.9
# remove this when we use newer Nim
#proc newLitFixed*(arg: enum): NimNode {.compileTime.} =
#  result = newCall(
#    arg.type.getTypeInst[1],
#    newLit(int(arg))
#  )

type
  VMWord* = array[32, byte]
  Storage* = tuple[key, val: VMWord]

  Assembler* = object
    title*   : string
    stack*   : seq[VMWord]
    memory*  : seq[VMWord]
    storage* : seq[Storage]
    code*    : seq[byte]
    logs*    : seq[Log]
    success* : bool
    gasLimit*: GasInt
    gasUsed* : GasInt
    data*    : seq[byte]
    output*  : seq[byte]

  MacroAssembler = object
    setup    : NimNode
    asmBlock : Assembler
    forkStr  : string

const
  idToOpcode = CacheTable"NimbusMacroAssembler"
var
  coreDbType* = DefaultDbMemory
    ## This variable needs to be accessible for unit tests like
    ## `test_op_memory` which implicitely uses the `initStorageTrie()` call
    ## from the `distinct_tries` module. The `Aristo` API cannot handle that
    ## because it needs the account address for accessing the storage trie.
    ##
    ## This problem can be fixed here in the `verifyAsmResult()` function once
    ## there is the time to do it ...

static:
  for n in Op:
    idToOpcode[$n] = newLit(ord(n))

  # EIP-4399 new opcode
  idToOpcode["PrevRandao"] = newLit(ord(Difficulty))

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
  doAssert(val[1].len == 1)
  val[1][0].expectKind(nnkStrLit)
  result = (validateVMWord(val[0]), validateVMWord(val[1][0]))

proc parseStorage(list: NimNode): seq[Storage] =
  result = @[]
  list.expectKind nnkStmtList
  for val in list:
    result.add validateStorage(val)

proc parseStringLiteral(node: NimNode): string =
  let strNode = node[0]
  strNode.expectKind(nnkStrLit)
  strNode.strVal

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
  node.expectKind({nnkPar, nnkTupleConstr})
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
  for pc, line in codes:
    line.expectKind({nnkCommand, nnkIdent, nnkStrLit})
    if line.kind == nnkStrLit:
      result.add hexToSeqByte(line.strVal)
    elif line.kind == nnkIdent:
      let sym = bindSym(line)
      validateOpcode(sym)
      result.addOpCode(sym, emptyNode)
    elif line.kind == nnkCommand:
      let sym = bindSym(line[0])
      validateOpcode(sym)
      var params = newNimNode(nnkBracket)
      for i in 1 ..< line.len:
        params.add line[i]
      result.addOpCode(sym, params)
    else:
      error("unknown syntax: " & line.toStrLit.strVal, line)

proc parseFork(fork: NimNode): string =
  fork[0].expectKind({nnkIdent, nnkStrLit})
  fork[0].strVal

proc parseGasUsed(gas: NimNode): GasInt =
  gas[0].expectKind(nnkIntLit)
  result = gas[0].intVal

proc parseAssembler(list: NimNode): MacroAssembler =
  result.forkStr = "Frontier"
  result.asmBlock.success = true
  result.asmBlock.gasUsed = -1
  list.expectKind nnkStmtList
  for callSection in list:
    callSection.expectKind(nnkCall)
    let label = callSection[0].strVal
    let body  = callSection[1]
    case label.normalize
    of "title"  : result.asmBlock.title   = parseStringLiteral(body)
    of "code"   : result.asmBlock.code    = parseCode(body)
    of "memory" : result.asmBlock.memory  = parseVMWords(body)
    of "stack"  : result.asmBlock.stack   = parseVMWords(body)
    of "storage": result.asmBlock.storage = parseStorage(body)
    of "logs"   : result.asmBlock.logs    = parseLogs(body)
    of "success": result.asmBlock.success = parseSuccess(body)
    of "data"   : result.asmBlock.data    = parseData(body)
    of "output" : result.asmBlock.output  = parseData(body)
    of "gasused": result.asmBlock.gasUsed = parseGasUsed(body)
    of "fork"   : result.forkStr = parseFork(body)
    of "setup"  : result.setup   = body
    else: error("unknown section '" & label & "'", callSection[0])

type VMProxy = tuple[sym: NimNode, pr: NimNode]

proc generateVMProxy(masm: MacroAssembler): VMProxy =
  let
    vmProxySym = genSym(nskProc, "vmProxy")
    body = newLitFixed(masm.asmBlock)
    setup = if masm.setup.isNil:
              newEmptyNode()
            else:
              masm.setup
    vmState = ident("vmState")
    fork = masm.forkStr
    vmProxyProc = quote do:
      proc `vmProxySym`(): bool =
        let `vmState` = initVMEnv(`fork`)
        `setup`
        let boa = `body`
        runVM(`vmState`, boa)
  (vmProxySym, vmProxyProc)

proc generateAssemblerTest(masm: MacroAssembler): NimNode =
  let
    (vmProxySym, vmProxyProc) = generateVMProxy(masm)
    title: string = masm.asmBlock.title

  result = quote do:
    test `title`:
      `vmProxyProc`
      {.gcsafe.}:
        check `vmProxySym`()

  when defined(macro_assembler_debug):
    echo result.toStrLit.strVal

const
  codeAddress = hexToByteArray[20]("460121576cc7df020759730751f92bd62fd78dd6")
  coinbase = hexToByteArray[20]("bb7b8287f3f0a933474a79eae42cbca977791171")

proc initVMEnv*(network: string): BaseVMState =
  let
    conf = getChainConfig(network)
    cdb = block:
      # Need static binding
      case coreDbType:
      of AristoDbMemory: newCoreDbRef AristoDbMemory
      else: raiseAssert "unsupported: " & $coreDbType
    com = CommonRef.new(
      cdb,
      conf,
      conf.chainId.NetworkId)
    parent = BlockHeader(stateRoot: EMPTY_ROOT_HASH)
    parentHash = rlpHash(parent)
    header = BlockHeader(
      blockNumber: 1.u256,
      stateRoot: EMPTY_ROOT_HASH,
      parentHash: parentHash,
      coinbase: coinbase,
      timestamp: EthTime(0x1234),
      difficulty: 1003.u256,
      gasLimit: 100_000
    )

  com.initializeEmptyDb()
  BaseVMState.new(parent, header, com)

proc verifyAsmResult(vmState: BaseVMState, boa: Assembler, asmResult: CallResult): bool =
  let com = vmState.com
  if not asmResult.isError:
    if boa.success == false:
      error "different success value", expected=boa.success, actual=true
      return false
  else:
    if boa.success == true:
      error "different success value", expected=boa.success, actual=false
      return false

  if boa.gasUsed != -1:
    if boa.gasUsed != asmResult.gasUsed:
      error "different gasUsed", expected=boa.gasUsed, actual=asmResult.gasUsed
      return false

  if boa.stack.len != asmResult.stack.values.len:
    error "different stack len", expected=boa.stack.len, actual=asmResult.stack.values.len
    return false

  for i, v in asmResult.stack.values:
    let actual = v.dumpHex()
    let val = boa.stack[i].toHex()
    if actual != val:
      error "different stack value", idx=i, expected=val, actual=actual
      return false

  const chunkLen = 32
  let numChunks = asmResult.memory.len div chunkLen

  if numChunks != boa.memory.len:
    error "different memory len", expected=boa.memory.len, actual=numChunks
    return false

  for i in 0 ..< numChunks:
    let actual = asmResult.memory.bytes.toOpenArray(i * chunkLen, (i + 1) * chunkLen - 1).toHex()
    let mem = boa.memory[i].toHex()
    if mem != actual:
      error "different memory value", idx=i, expected=mem, actual=actual
      return false

  var stateDB = vmState.stateDB
  stateDB.persist()
  var
    storageRoot = stateDB.getStorageRoot(codeAddress)
    trie = initStorageTrie(com.db, storageRoot)

  for kv in boa.storage:
    let key = kv[0].toHex()
    let val = kv[1].toHex()
    let keyBytes = (@(kv[0]))
    let actual = trie.getSlotBytes(keyBytes).toHex()
    let zerosLen = 64 - (actual.len)
    let value = repeat('0', zerosLen) & actual
    if val != value:
      error "storage has different value", key=key, expected=val, actual=value
      return false

  let logs = vmState.getAndClearLogEntries()
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
    let actual = asmResult.output.toHex()
    let expected = boa.output.toHex()
    if expected != actual:
      error "different output detected", expected=expected, actual=actual
      return false

  result = true

proc createSignedTx(payload: Blob, chainId: ChainId): Transaction =
  let privateKey = PrivateKey.fromHex("7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")[]
  let unsignedTx = Transaction(
    txType: TxEIP4844,
    nonce: 0,
    gasPrice: 1.GasInt,
    gasLimit: 500_000_000.GasInt,
    to: codeAddress.some,
    value: 500.u256,
    payload: payload,
    versionedHashes: @[EMPTY_UNCLE_HASH, EMPTY_SHA3]
  )
  signTransaction(unsignedTx, privateKey, chainId, false)

proc runVM*(vmState: BaseVMState, boa: Assembler): bool =
  let
    com  = vmState.com
    fork = com.toEVMFork()
  vmState.mutateStateDB:
    db.setCode(codeAddress, boa.code)
    db.setBalance(codeAddress, 1_000_000.u256)
  let tx = createSignedTx(boa.data, com.chainId)
  let asmResult = testCallEvm(tx, tx.getSender, vmState, fork)
  verifyAsmResult(vmState, boa, asmResult)

macro assembler*(list: untyped): untyped =
  result = parseAssembler(list).generateAssemblerTest()

macro evmByteCode*(list: untyped): untyped =
  list.expectKind nnkStmtList
  var code = parseCode(list)
  result = newLitFixed(code)
