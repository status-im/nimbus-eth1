import
  faststreams/input_stream, eth/[common, rlp], stint, stew/endians2,
  eth/trie/[db, trie_defs], nimcrypto/[keccak, hash],
  ./witness_types, stew/byteutils, ../nimbus/constants

type
  DB = TrieDatabaseRef

  NodeKey = object
    usedBytes: int
    data*: array[32, byte]

  TreeBuilder = object
    when defined(useInputStream):
      input: InputStream
    else:
      input: seq[byte]
      pos: int
    db: DB
    root: KeccakHash
    flags: WitnessFlags

# the InputStream still unstable
# when using large dataset for testing
# or run longer

when defined(useInputStream):
  proc initTreeBuilder*(input: InputStream, db: DB, flags: WitnessFlags): TreeBuilder =
    result.input = input
    result.db = db
    result.root = emptyRlpHash
    result.flags = flags

  proc initTreeBuilder*(input: openArray[byte], db: DB, flags: WitnessFlags): TreeBuilder =
    result.input = memoryInput(input)
    result.db = db
    result.root = emptyRlpHash
    result.flags = flags
else:
  proc initTreeBuilder*(input: openArray[byte], db: DB, flags: WitnessFlags): TreeBuilder =
    result.input = @input
    result.db = db
    result.root = emptyRlpHash
    result.flags = flags

func rootHash*(t: TreeBuilder): KeccakHash {.inline.} =
  t.root

when defined(useInputStream):
  template readByte(t: var TreeBuilder): byte =
    t.input.read

  template len(t: TreeBuilder): int =
    t.input.len

  template read(t: var TreeBuilder, len: int): auto =
    t.input.read(len)

  template readable(t: var TreeBuilder): bool =
    t.input.readable

  template readable(t: var TreeBuilder, len: int): bool =
    t.input.readable(len)

else:
  template readByte(t: var TreeBuilder): byte =
    let pos = t.pos
    inc t.pos
    t.input[pos]

  template len(t: TreeBuilder): int =
    t.input.len

  template readable(t: var TreeBuilder): bool =
    t.pos < t.input.len

  template readable(t: var TreeBuilder, length: int): bool =
    t.pos + length <= t.input.len

  template read(t: var TreeBuilder, len: int): auto =
    let pos = t.pos
    inc(t.pos, len)
    toOpenArray(t.input, pos, pos+len-1)

proc safeReadByte(t: var TreeBuilder): byte =
  if t.readable:
    result = t.readByte()
  else:
    raise newException(IOError, "Cannot read byte from input stream")

proc safeReadU32(t: var TreeBuilder): uint32 =
  if t.readable(4):
    result = fromBytesBE(uint32, t.read(4))
  else:
    raise newException(IOError, "Cannot read U32 from input stream")

proc toKeccak(r: var NodeKey, x: openArray[byte]) {.inline.} =
  r.data[0..31] = x[0..31]
  r.usedBytes = 32

proc append(r: var RlpWriter, n: NodeKey) =
  if n.usedBytes < 32:
    r.append rlpFromBytes(n.data.toOpenArray(0, n.usedBytes-1))
  else:
    r.append n.data.toOpenArray(0, n.usedBytes-1)

proc toNodeKey(t: var TreeBuilder, z: openArray[byte]): NodeKey =
  if z.len < 32:
    result.usedBytes = z.len
    result.data[0..z.len-1] = z[0..z.len-1]
  else:
    result.data = keccak(z).data
    result.usedBytes = 32
    t.db.put(result.data, z)

proc writeCode(t: var TreeBuilder, code: openArray[byte]): Hash256 =
  result = keccak(code)
  put(t.db, result.data, code)

proc branchNode(t: var TreeBuilder, depth: int, storageMode: bool): NodeKey
proc extensionNode(t: var TreeBuilder, depth: int, storageMode: bool): NodeKey
proc accountNode(t: var TreeBuilder, depth: int): NodeKey
proc accountStorageLeafNode(t: var TreeBuilder, depth: int): NodeKey
proc hashNode(t: var TreeBuilder): NodeKey
proc treeNode(t: var TreeBuilder, depth: int = 0, storageMode = false): NodeKey

proc buildTree*(t: var TreeBuilder): KeccakHash =
  let version = t.safeReadByte().int
  if version != BlockWitnessVersion.int:
    raise newException(ParsingError, "Wrong block witness version")

  # one or more trees

  # we only parse one tree here
  let metadataType = t.safeReadByte().int
  if metadataType != MetadataNothing.int:
    raise newException(ParsingError, "This tree builder support no metadata")

  var res = treeNode(t)
  if res.usedBytes != 32:
    raise newException(ParsingError, "Buildtree should produce hash")

  result.data = res.data

proc buildForest*(t: var TreeBuilder): seq[KeccakHash] =
  let version = t.safeReadByte().int
  if version != BlockWitnessVersion.int:
    raise newException(ParsingError, "Wrong block witness version")

  while t.readable:
    let metadataType = t.safeReadByte().int
    if metadataType != MetadataNothing.int:
      raise newException(ParsingError, "This tree builder support no metadata")

    var res = treeNode(t)
    if res.usedBytes != 32:
      raise newException(ParsingError, "Buildtree should produce hash")

    result.add KeccakHash(data: res.data)

proc treeNode(t: var TreeBuilder, depth: int = 0, storageMode = false): NodeKey =
  assert(depth < 64)
  let typ = t.safeReadByte().int
  if typ < low(TrieNodeType).int or typ > high(TrieNodeType).int:
    raise newException(ParsingError, "Wrong trie node type")

  let nodeType = TrieNodeType(typ)
  case nodeType
  of BranchNodeType: result = t.branchNode(depth, storageMode)
  of ExtensionNodeType: result = t.extensionNode(depth, storageMode)
  of AccountNodeType:
    if storageMode:
      # parse account storage leaf node
      result = t.accountStorageLeafNode(depth)
    else:
      result = t.accountNode(depth)
  of HashNodeType: result = t.hashNode()

  if depth == 0 and result.usedBytes < 32:
    let hash = keccak(result.data.toOpenArray(0, result.usedBytes-1))
    t.db.put(hash.data, result.data.toOpenArray(0, result.usedBytes-1))
    result.data = hash.data
    result.usedBytes = 32


proc branchNode(t: var TreeBuilder, depth: int, storageMode: bool): NodeKey =
  assert(depth < 64)
  let mask = constructBranchMask(t.safeReadByte, t.safeReadByte)

  when defined(debugDepth):
    let readDepth = t.safeReadByte().int
    doAssert(readDepth == depth, "branchNode " & $readDepth & " vs. " & $depth)

  when defined(debugHash):
    let hash = toKeccak(t.read(32))

  var r = initRlpList(17)

  for i in 0 ..< 16:
    if mask.branchMaskBitIsSet(i):
      r.append t.treeNode(depth+1, storageMode)
    else:
      r.append ""

  if branchMaskBitIsSet(mask, 16):
    raise newException(ParsingError, "The 17th elem of branh node should empty")

  # 17th elem should always empty
  r.append ""

  result = t.toNodeKey(r.finish)

  when defined(debugHash):
    if result != hash:
      debugEcho "DEPTH: ", depth
      debugEcho "result: ", result.data.toHex, " vs. ", hash.data.toHex

func hexPrefix(r: var RlpWriter, x: openArray[byte], nibblesLen: int, isLeaf: static[bool] = false) =
  doAssert(nibblesLen <= 64)
  var bytes: array[33, byte]
  if (nibblesLen mod 2) == 0: # even
    when isLeaf:
      bytes[0] = 0b0010_0000.byte
    else:
      bytes[0] = 0.byte
    var i = 1
    for y in x:
      bytes[i] = y
      inc i
  else: # odd
    when isLeaf:
      bytes[0] = 0b0011_0000.byte or (x[0] shr 4)
    else:
      bytes[0] = 0b0001_0000.byte or (x[0] shr 4)
    var last = nibblesLen div 2
    for i in 1..last:
      bytes[i] = (x[i-1] shl 4) or (x[i] shr 4)

  r.append toOpenArray(bytes, 0, nibblesLen div 2)

proc extensionNode(t: var TreeBuilder, depth: int, storageMode: bool): NodeKey =
  assert(depth < 63)
  let nibblesLen = t.safeReadByte().int
  assert(nibblesLen < 65)
  var r = initRlpList(2)
  let pathLen = nibblesLen div 2 + nibblesLen mod 2
  if t.readable(pathLen):
    r.hexPrefix(t.read(pathLen), nibblesLen)
  else:
    raise newException(ParsingError, "Failed when read nibbles path")

  when defined(debugDepth):
    let readDepth = t.safeReadByte().int
    doAssert(readDepth == depth, "extensionNode " & $readDepth & " vs. " & $depth)

  when defined(debugHash):
    let hash = toKeccak(t.read(32))

  assert(depth + nibblesLen < 65)
  let typ = t.safeReadByte.int
  if typ < low(TrieNodeType).int or typ > high(TrieNodeType).int:
    raise newException(ParsingError, "Wrong trie node type")

  let nodeType = TrieNodeType(typ)
  case nodeType
  of BranchNodeType: r.append t.branchNode(depth + nibblesLen, storageMode)
  of HashNodeType: r.append t.hashNode()
  else: raise newException(ValueError, "wrong type during parsing child of extension node")

  result = t.toNodeKey(r.finish)

  when defined(debugHash):
    if result != hash:
      debugEcho "DEPTH: ", depth
    doAssert(result == hash, "EXT HASH DIFF " & result.data.toHex & " vs. " & hash.data.toHex)

proc accountNode(t: var TreeBuilder, depth: int): NodeKey =
  assert(depth < 65)

  when defined(debugHash):
    let len = t.safeReadU32().int
    let node = @(t.read(len))
    let nodeKey = t.toNodeKey(node)

  when defined(debugDepth):
    let readDepth = t.safeReadByte().int
    doAssert(readDepth == depth, "accountNode " & $readDepth & " vs. " & $depth)

  let typ = t.safeReadByte.int
  if typ < low(AccountType).int or typ > high(AccountType).int:
    raise newException(ParsingError, "Wrong account type")

  let accountType = AccountType(typ)
  let nibblesLen = 64 - depth
  var r = initRlpList(2)

  let pathLen = nibblesLen div 2 + nibblesLen mod 2
  if t.readable(pathLen):
    r.hexPrefix(t.read(pathLen), nibblesLen, true)
  else:
    raise newException(ParsingError, "Failed when read nibbles path")

  # TODO: parse address
  # let address = toAddress(t.read(20))

  if not t.readable(64):
    raise newException(ParsingError, "Not enough bytes to read account")

  var acc = Account(
    balance: UInt256.fromBytesBE(t.read(32), false),
    # TODO: why nonce must be 32 bytes, isn't 64 bit uint  enough?
    nonce: UInt256.fromBytesBE(t.read(32), false).truncate(AccountNonce)
  )

  if accountType == SimpleAccountType:
    acc.codeHash = blankStringHash
    acc.storageRoot = emptyRlpHash
  else:
    let codeLen = t.safeReadU32()
    if wfEIP170 in t.flags and codeLen > EIP170_CODE_SIZE_LIMIT:
      raise newException(ContractCodeError, "code len exceed EIP170 code size limit")

    if t.readable(codeLen.int):
      acc.codeHash = t.writeCode(t.read(codeLen.int))
    else:
      raise newException(ParsingError, "not enought bytes to read contract code")

    # switch to account storage parsing mode
    # and reset the depth
    let storageRoot = t.treeNode(0, storageMode = true)
    doAssert(storageRoot.usedBytes == 32)
    acc.storageRoot.data = storageRoot.data

  r.append rlp.encode(acc)
  let nodeRes = r.finish
  result = t.toNodeKey(nodeRes)

  when defined(debugHash):
    if result != nodeKey:
      debugEcho "result.usedBytes: ", result.usedBytes
      debugEcho "nodeKey.usedBytes: ", nodeKey.usedBytes
      var rlpa = rlpFromBytes(node)
      var rlpb = rlpFromBytes(nodeRes)
      debugEcho "Expected: ", inspect(rlpa)
      debugEcho "Actual: ", inspect(rlpb)
      var a = rlpa.listElem(1).toBytes.decode(Account)
      var b = rlpb.listElem(1).toBytes.decode(Account)
      debugEcho "Expected: ", a
      debugEcho "Actual: ", b

    doAssert(result == nodeKey, "account node parsing error")

proc accountStorageLeafNode(t: var TreeBuilder, depth: int): NodeKey =
  assert(depth < 65)
  let nibblesLen = 64 - depth
  var r = initRlpList(2)
  let pathLen = nibblesLen div 2 + nibblesLen mod 2
  if not t.readable(pathLen):
    raise newException(ParsingError, "Enot enough bytes to read path nibbles")

  r.hexPrefix(t.read(pathLen), nibblesLen, true)
  # TODO: parse key
  # let key = @(t.read(32))
  # UInt256 -> BytesBE -> keccak

  if not t.readable(32):
    raise newException(ParsingError, "Not enough bytes to read path storage value")

  let val = UInt256.fromBytesBE(t.read(32))
  r.append rlp.encode(val)
  result = t.toNodeKey(r.finish)

proc hashNode(t: var TreeBuilder): NodeKey =
  if not t.readable(32):
    raise newException(ParsingError, "Not enough bytes to read hash node")
  result.toKeccak(t.read(32))
