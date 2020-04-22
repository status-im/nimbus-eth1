import
  faststreams/input_stream, eth/[common, rlp], stint, stew/endians2,
  eth/trie/[db, trie_defs], nimcrypto/[keccak, hash],
  ./witness_types, stew/byteutils

type
  DB = TrieDatabaseRef

  TreeBuilder = object
    data: seq[byte]
    pos: int
    #input: InputStream
    db: DB
    root: KeccakHash

# InputStream is unstable, so we hack our own inputstream
#proc initTreeBuilder*(input: InputStream, db: DB): TreeBuilder =
  #result.input = input
  #result.db = db
  #result.root = emptyRlpHash

proc initTreeBuilder*(input: openArray[byte], db: DB): TreeBuilder =
  result.data = @input
  result.db = db
  result.root = emptyRlpHash

func rootHash*(t: TreeBuilder): KeccakHash {.inline.} =
  t.root

proc writeNode(t: var TreeBuilder, n: openArray[byte]): KeccakHash =
  result = keccak(n)
  t.db.put(result.data, n)

proc readByte(t: var TreeBuilder): byte =
  if t.pos < t.data.len:
    result = t.data[t.pos]
    inc t.pos

template len(t: TreeBuilder): int =
  t.data.len

proc peek(t: TreeBuilder): byte =
  if t.pos + 1 < t.data.len:
    result = t.data[t.pos + 1]

template read(t: var TreeBuilder, len: int): auto =
  let pos = t.pos
  inc(t.pos, len)
  toOpenArray(t.data, pos, pos + len - 1)

proc readU32(t: var TreeBuilder): int =
  # TODO: what if the value overflow int32.high?
  result = fromBytesLE(uint32, t.read(4)).int

proc toAddress(r: var EthAddress, x: openArray[byte]) {.inline.} =
  r[0..19] = x[0..19]

proc toKeccak(r: var KeccakHash, x: openArray[byte]) {.inline.} =
  r.data[0..31] = x[0..31]

proc toKeccak(x: openArray[byte]): KeccakHash {.inline.} =
  result.data[0..31] = x[0..31]

proc branchNode(t: var TreeBuilder, depth: int, has16Elem: bool = true): KeccakHash
proc extensionNode(t: var TreeBuilder, depth: int): KeccakHash
proc accountNode(t: var TreeBuilder, depth: int): KeccakHash
proc accountStorageLeafNode(t: var TreeBuilder, depth: int): KeccakHash
proc hashNode(t: var TreeBuilder): KeccakHash

proc treeNode*(t: var TreeBuilder, depth: int = 0, accountMode = false): KeccakHash =
  assert(depth < 64)
  let nodeType = TrieNodeType(t.readByte)

  case nodeType
  of BranchNodeType: result = t.branchNode(depth)
  of Branch17NodeType: result = t.branchNode(depth, false)
  of ExtensionNodeType: result = t.extensionNode(depth)
  of AccountNodeType:
    if accountMode:
      # parse account storage leaf node
      result = t.accountStorageLeafNode(depth)
    else:
      result = t.accountNode(depth)
  of HashNodeType: result = t.hashNode()

proc branchNode(t: var TreeBuilder, depth: int, has16Elem: bool): KeccakHash =
  assert(depth < 64)
  let mask = constructBranchMask(t.readByte, t.readByte)
  var r = initRlpList(17)

  for i in 0 ..< 16:
    if mask.branchMaskBitIsSet(i):
      r.append t.treeNode(depth+1)
    else:
      r.append ""

  template safePeek(t: var TreeBuilder): int =
    if t.len == 0 or has16Elem:
      -1
    else:
      t.peek().int

  # add the 17th elem
  let nodeType = t.safePeek()
  if nodeType == AccountNodeType.int:
    r.append accountNode(t, depth+1)
  elif nodeType == HashNodeType.int:
    r.append hashNode(t)
  else:
    # anything else is empty
    r.append ""

  result = keccak(r.finish)

func hexPrefix(x: openArray[byte], nibblesLen: int): seq[byte] =
  result = newSeqOfCap[byte]((nibblesLen div 2) + 1)
  if (nibblesLen mod 2) == 0:
    result.add 0.byte
    for y in x:
      result.add y
  else:
    result.add(0b0001_0000.byte or (x[0] shr 4))
    var last = nibblesLen div 2
    for i in 1..last:
      result.add((x[i-1] shl 4) or (x[i] shr 4))

proc extensionNode(t: var TreeBuilder, depth: int): KeccakHash =
  assert(depth < 63)
  let nibblesLen = int(t.readByte)
  assert(nibblesLen < 65)
  var r = initRlpList(2)
  r.append hexPrefix(t.read(nibblesLen div 2 + nibblesLen mod 2), nibblesLen)

  assert(depth + nibblesLen < 65)
  let nodeType = TrieNodeType(t.readByte)

  case nodeType
  of BranchNodeType: r.append t.branchNode(depth + nibblesLen)
  of Branch17NodeType: r.append t.branchNode(depth + nibblesLen, false)
  of HashNodeType: r.append t.hashNode()
  else: raise newException(ValueError, "wrong type during parsing child of extension node")

  result = keccak(r.finish)

proc accountNode(t: var TreeBuilder, depth: int): KeccakHash =
  assert(depth < 65)
  let len = t.readU32()
  t.writeNode(t.read(len))

  #[let nodeType = AccountType(t.readByte)
  let nibblesLen = 64 - depth
  let pathNibbles = @(t.read(nibblesLen div 2 + nibblesLen mod 2))
  let address = toAddress(t.read(20))
  let balance = UInt256.fromBytesBE(t.read(32), false)
  # TODO: why nonce must be 32 bytes, isn't 64 bit uint  enough?
  let nonce = UInt256.fromBytesBE(t.read(32), false)
  if nodeType == ExtendedAccountType:
    let codeLen = t.readU32()
    let code = @(t.read(codeLen))
    # switch to account storage parsing mode
    # and reset the depth
    t.treeNode(0, accountMode = true)]#

proc accountStorageLeafNode(t: var TreeBuilder, depth: int): KeccakHash =
  assert(depth < 65)
  let nibblesLen = 64 - depth
  let pathNibbles = @(t.read(nibblesLen div 2 + nibblesLen mod 2))
  let key = @(t.read(32))
  let val = @(t.read(32))

proc hashNode(t: var TreeBuilder): KeccakHash =
  result.toKeccak(t.read(32))
