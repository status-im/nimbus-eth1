import faststreams/input_stream, eth/common, stint

type
  TrieNodeType = enum
    BranchNodeType
    ExtensionNodeType
    AccountNodeType
    HashNodeType

  AccountType = enum
    SimpleAccountType
    ExtendedAccountType

  TreeBuilder = object
    input: ByteStreamVar

func constructBranchMask(b1, b2: byte): uint {.inline.} =
  uint(b1) shl 8 or uint(b2)

proc setBranchMaskBit(x: var uint, i: int) {.inline.} =
  assert(i >= 0 and i < 16)
  x = x or (1 shl i).uint

func branchMaskBitIsSet(x: uint, i: int): bool {.inline.} =
  assert(i >= 0 and i < 16)
  result = ((x shr i.uint) and 1'u) == 1'u

template readByte(t: var TreeBuilder): byte =
  t.input[].read

proc readU32(t: var TreeBuilder): int =
  result = t.input[].read.int
  result = result or (t.input[].read.int shl 8)
  result = result or (t.input[].read.int shl 16)
  result = result or (t.input[].read.int shl 24)

proc branchNode(t: var TreeBuilder, depth: int)
proc extensionNode(t: var TreeBuilder, depth: int)
proc accountNode(t: var TreeBuilder, depth: int)
proc accountStorageLeafNode(t: var TreeBuilder, depth: int)
proc hashNode(t: var TreeBuilder)

proc treeNode(t: var TreeBuilder, depth: int = 0, accountMode = false) =
  assert(depth < 64)
  let nodeType = TrieNodeType(t.readByte)
  case nodeType
  of BranchNodeType: t.branchNode(depth)
  of ExtensionNodeType: t.extensionNode(depth)
  of AccountNodeType:
    if accountMode:
      # parse account storage leaf node
      t.accountStorageLeafNode(depth)
    else:
      t.accountNode(depth)
  of HashNodeType: t.hashNode()

proc branchNode(t: var TreeBuilder, depth: int) =
  assert(depth < 64)
  let mask = constructBranchMask(t.readByte, t.readByte)
  for i in 0 ..< 16:
    if mask.branchMaskBitIsSet(i):
      t.treeNode(depth+1)

proc extensionNode(t: var TreeBuilder, depth: int) =
  assert(depth < 63)
  let nibblesLen = int(t.readByte)
  assert(nibblesLen < 65)
  let pathNibbles = @(t.input.readBytes(nibblesLen div 2 + nibblesLen mod 2))

  assert(depth + nibblesLen < 65)
  let nodeType = TrieNodeType(t.readByte)
  case nodeType
  of BranchNodeType: t.branchNode(depth + nibblesLen)
  of HashNodeType: t.hashNode()
  else: raise newException(ValueError, "wrong type during parsing child of extension node")

func toAddress(x: openArray[byte]): EthAddress {.inline.} =
  result[0..19] = x[0..19]

proc accountNode(t: var TreeBuilder, depth: int) =
  assert(depth < 65)
  let nodeType = AccountType(t.readByte)
  let nibblesLen = 64 - depth
  let pathNibbles = @(t.input.readBytes(nibblesLen div 2 + nibblesLen mod 2))
  let address = toAddress(t.input.readBytes(20))
  let balance = UInt256.fromBytesBE(t.input.readBytes(32), false)
  # TODO: why nonce must be 32 bytes, isn't 64 bit uint  enough?
  let nonce = UInt256.fromBytesBE(t.input.readBytes(32), false)
  if nodeType == ExtendedAccountType:
    let codeLen = t.readU32()
    let code = @(t.input.readBytes(codeLen))
    # switch to account storage parsing mode
    # and reset the depth
    t.treeNode(0, accountMode = true)

proc accountStorageLeafNode(t: var TreeBuilder, depth: int) =
  assert(depth < 65)
  let nibblesLen = 64 - depth
  let pathNibbles = @(t.input.readBytes(nibblesLen div 2 + nibblesLen mod 2))
  let key = @(t.input.readBytes(32))
  let val = @(t.input.readBytes(32))

proc hashNode(t: var TreeBuilder) =
  let hash = @(t.input.readBytes(32))
