import
  eth/common, eth/trie/db, json, os, unittest,
  ../stateless/[tree_from_witness],
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

proc processHashNode(t: var Tester, x: JsonNode) =
  t.write(x["data"])

proc processNode(t: var Tester, x: JsonNode, storageMode: bool = false)

proc processStorage(t: var Tester, tree: JsonNode) =
  for x in tree:
    t.processNode(x, true)

proc processByteCode(t: var Tester, x: JsonNode) =
  let codeType = x["codeType"].getStr()
  t.write(codeType)
  case codeType
  of "0x00":
    let codeLen = x["codeLen"].getStr()
    t.write(codeLen)
    if codeLen != "0x00000000":
      t.write(x["code"])
  of "0x01":
    t.write(x["codeLen"])
    t.write("0x03")
    t.processHashNode(x["codeHash"])
  else:
    doAssert(false, "wrong bytecode type")

proc processAccountNode(t: var Tester, x: JsonNode) =
  let accountType = x["accountType"].getStr()
  t.write(accountType)
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
    doAssert(false, "wrong account type")

proc processStorageLeafNode(t: var Tester, x: JsonNode) =
  t.write(x["key"])
  t.write(x["value"])

proc processNode(t: var Tester, x: JsonNode, storageMode: bool = false) =
  let nodeType = x["nodeType"].getStr()
  t.write(nodeType)
  case nodeType
  of "0x00": t.processBranchNode(x)
  of "0x01": t.processExtensionNode(x)
  of "0x02":
    if storageMode:
      t.processStorageLeafNode(x)
    else:
      t.processAccountNode(x)
  of "0x03": t.processHashNode(x)
  else:
    doAssert(false, "wrong node type")

proc parseRootHash(x: string): KeccakHash =
  result.data = hexToByteArray[32](x)

proc parseTester(t: var Tester, n: JsonNode) =
  t.error = n["error"].getBool()
  t.rootHash = parseRootHash(n["rootHash"].getStr())
  t.write(n["version"])
  t.write(n["metadata"])

  let tree = n["tree"]
  for x in tree:
    t.processNode(x)

proc parseTester(filename: string): Tester =
  let n = parseFile(filename)
  parseTester(result, n)

proc runTest(filePath, fileName: string) =
  test fileName:
    let t = parseTester(filePath)
    var db = newMemoryDB()
    var tb = initTreeBuilder(t.output, db, {wfEIP170})
    let root = tb.buildTree()
    check root == t.rootHash

proc witnessJsonMain*() =
  for x in walkDirRec("stateless" / "fixtures"):
    let y = splitPath(x)
    runTest(x, y.tail)

when isMainModule:
  witnessJsonMain()
