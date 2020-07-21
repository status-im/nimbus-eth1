import
  eth/common, eth/trie/db, json, os, unittest2,
  ./tree_from_witness, parseopt,
  ./witness_types, stew/byteutils

type
  Tester = object
    rootHash: KeccakHash
    error: bool
    output: seq[byte]

proc write(t: var Tester, x: openArray[byte]) =
  t.output.add x

proc write(t: var Tester, x: string) =
  let len = (x.len - 2) div 2
  var buf: array[4096, byte]
  hexToByteArray(x, buf, 0, len - 1)
  t.write(buf.toOpenArray(0, len - 1))

proc write(t: var Tester, x: JsonNode) =
  t.write(x.getStr())

proc processBranchNode(t: var Tester, x: JsonNode) =
  t.write(x["mask"])

proc processExtensionNode(t: var Tester, x: JsonNode) =
  t.write(x["nibblesLen"])
  t.write(x["nibbles"])

proc processNode(t: var Tester, x: JsonNode, storageMode: bool = false)

proc writeSub(t: var Tester, x: JsonNode, name: string): string =
  let subName = name & "Sub"
  let nodeType = x[name].getStr()
  if subName in x:
    let subType = x[subName].getStr()
    t.write(subType)
  else:
    t.write(nodeType)
  result = nodeType

proc processHashNode(t: var Tester, x: JsonNode) =
  discard t.writeSub(x, "nodeType")
  t.write(x["data"])

proc processStorage(t: var Tester, tree: JsonNode) =
  for x in tree:
    t.processNode(x, true)

proc processByteCode(t: var Tester, x: JsonNode) =
  let codeType = t.writeSub(x, "codeType")
  case codeType
  of "0x00":
    let codeLen = x["codeLen"].getStr()
    t.write(codeLen)
    if codeLen != "0x00":
      t.write(x["code"])
  of "0x01":
    t.write(x["codeLen"])
    t.processHashNode(x["codeHash"])
  else:
    raise newException(ParsingError, "wrong bytecode type")

proc processAccountNode(t: var Tester, x: JsonNode) =
  let accountType = t.writeSub(x, "accountType")
  t.write(x["address"])
  t.write(x["balance"])
  t.write(x["nonce"])

  case accountType:
  of "0x00":
    discard
  of "0x01":
    t.processByteCode(x)
    t.processStorage(x["storage"])
  else:
    raise newException(ParsingError, "wrong account type")

proc processStorageLeafNode(t: var Tester, x: JsonNode) =
  t.write(x["key"])
  t.write(x["value"])

proc processNode(t: var Tester, x: JsonNode, storageMode: bool = false) =
  let nodeType = t.writeSub(x, "nodeType")
  case nodeType
  of "0x00": t.processBranchNode(x)
  of "0x01": t.processExtensionNode(x)
  of "0x02":
    if storageMode:
      t.processStorageLeafNode(x)
    else:
      t.processAccountNode(x)
  of "0x03":
    t.write(x["data"])
  else:
    raise newException(ParsingError, "wrong node type")

proc parseRootHash(x: string): KeccakHash =
  result.data = hexToByteArray[32](x)

proc parseTester(t: var Tester, n: JsonNode, testStatusIMPL: var TestStatus) =
  t.error = n["error"].getBool()
  t.rootHash = parseRootHash(n["rootHash"].getStr())
  t.write(n["version"])
  t.write(n["metadata"])

  let tree = n["tree"]
  try:
    for x in tree:
      t.processNode(x)
  except ParsingError:
    check t.error == true

proc parseTester(filename: string, testStatusIMPL: var TestStatus): Tester =
  let n = parseFile(filename)
  parseTester(result, n, testStatusIMPL)

proc runTest(filePath, fileName: string) =
  test fileName:
    let t = parseTester(filePath, testStatusIMPL)
    var db = newMemoryDB()
    try:
      var tb = initTreeBuilder(t.output, db, {wfEIP170})
      let root = tb.buildTree()
      if t.error:
        check root != t.rootHash
      else:
        check root == t.rootHash
        check t.error == false
    except ParsingError, ContractCodeError:
      # echo "Exception detected ", getCurrentExceptionMsg()
      check t.error == true

proc writeFuzzData(filePath, fileName: string) =
  var testStatusIMPL: TestStatus
  let t = parseTester(filePath, testStatusIMPL)

  # this block below check the parsed json
  var db = newMemoryDB()
  var tb = initTreeBuilder(t.output, db, {wfEIP170})
  discard tb.buildTree()

  writeFile(filename, t.output)

proc fuzzTool(): bool {.used.} =
  var filename: string
  var numArg = 0

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      inc numArg
      case numArg
      of 1:
        if key != "fuzz":
          quit(1)
      of 2:
        filename = key
      else:
        discard
    of cmdLongOption, cmdShortOption:
      discard
    of cmdEnd: assert(false) # cannot happen

  if filename != "":
    echo "generate fuzz data"
    writeFuzzData(filename, "fuzz.data")
    return true

proc witnessJsonMain*() =
  suite "test tree builder against json fixtures":
    for x in walkDirRec("stateless" / "fixtures"):
      let y = splitPath(x)
      runTest(x, y.tail)

when isMainModule:
  if not fuzzTool():
    witnessJsonMain()
