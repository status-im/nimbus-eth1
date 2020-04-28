import
  stew/[byteutils, endians2],
  nimcrypto/[keccak, hash], eth/[common, rlp],
  eth/trie/[trie_defs, nibbles, db],
  faststreams/output_stream,
  ./witness_types, ../nimbus/constants

type
  DB = TrieDatabaseRef

  WitnessBuilder* = object
    db*: DB
    root: KeccakHash
    output: OutputStream

proc initWitnessBuilder*(db: DB, rootHash: KeccakHash = emptyRlpHash): WitnessBuilder =
  result.db = db
  result.root = rootHash
  result.output = memoryOutput().s

template extensionNodeKey(r: Rlp): auto =
  hexPrefixDecode r.listElem(0).toBytes

proc expectHash(r: Rlp): seq[byte] =
  result = r.toBytes
  if result.len != 32:
    raise newException(RlpTypeMismatch,
      "RLP expected to be a Keccak hash value, but has an incorrect length")

template getNode(elem: untyped): untyped =
  if elem.isList: @(elem.rawData)
  else: get(wb.db, elem.expectHash)

proc rlpListToBitmask(r: var Rlp): uint =
  var i = 0
  for branch in r:
    if not branch.isEmpty:
      result.setBranchMaskBit(i)
    inc i
  r.position = 0

proc writeU32(wb: var WitnessBuilder, x: uint32) =
  wb.output.append(toBytesBE(x))

proc writeNibbles(wb: var WitnessBuilder; n: NibblesSeq, withLen: bool = true) =
  let nibblesLen = n.len
  let numBytes = nibblesLen div 2 + nibblesLen mod 2
  var bytes: array[32, byte]
  doAssert(nibblesLen >= 1)
  doAssert(numBytes >= 0  and numBytes <= 64)
  for pos in 0..<n.len:
    if (pos and 1) != 0:
      bytes[pos div 2] = bytes[pos div 2] or n[pos]
    else:
      bytes[pos div 2] = bytes[pos div 2] or (n[pos] shl 4)

  if withLen:
    # write nibblesLen
    wb.output.append(nibblesLen.byte)
  # write nibbles
  wb.output.append(bytes.toOpenArray(0, numBytes-1))

proc writeExtensionNode(wb: var WitnessBuilder, n: NibblesSeq, depth: int, node: openArray[byte]) =
  # write type
  wb.output.append(ExtensionNodeType.byte)
  # write nibbles
  wb.writeNibbles(n)

  when defined(debugDepth):
    wb.output.append(depth.byte)

  when defined(debugHash):
    wb.output.append(keccak(node).data)

proc writeBranchNode(wb: var WitnessBuilder, mask: uint, depth: int, node: openArray[byte]) =
  # write type
  # branch node 17th elem should always empty
  doAssert mask.branchMaskBitIsSet(16) == false
  wb.output.append(BranchNodeType.byte)
  # write branch mask
  wb.output.append(((mask shr 8) and 0xFF).byte)
  wb.output.append((mask and 0xFF).byte)

  when defined(debugDepth):
    wb.output.append(depth.byte)

  when defined(debugHash):
    wb.output.append(keccak(node).data)

proc writeAccountNode(wb: var WitnessBuilder, acc: Account, nibbles: NibblesSeq, node: openArray[byte], depth: int) =
  # write type
  wb.output.append(AccountNodeType.byte)
  wb.writeU32(node.len.uint32)
  wb.output.append(node)

  when defined(debugDepth):
    wb.output.append(depth.byte)

  #EIP170_CODE_SIZE_LIMIT

  doAssert(nibbles.len == 64 - depth)
  let accountType = if acc.codeHash == blankStringHash or acc.storageRoot == emptyRlpHash: SimpleAccountType
                    else: ExtendedAccountType

  #wb.output.append(accountType.byte)
  #wb.writeNibbles(nibbles, false)
  #wb.output.append(acc.address)
  #wb.output.append(acc.balance.toBytesBE)
  #wb.output.append(acc.nonce.u256.toBytesBE)

  #if accountType == ExtendedAccountType:

  #0x00 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32>
  #0x01 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32> bytecode:<Bytecode> storage:<Tree_Node(0,1)>

  #<Bytecode> := len:<U32> b:<Byte>^len

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte]) =
  # write type
  wb.output.append(HashNodeType.byte)
  wb.output.append(node)

proc writeShortNode(wb: var WitnessBuilder, node: openArray[byte], depth: int) =
  var nodeRlp = rlpFromBytes node
  if not nodeRlp.hasData or nodeRlp.isEmpty: return
  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    if isLeaf:
      let acc = nodeRlp.listElem(1).toBytes.decode(Account)      
      writeAccountNode(wb, acc, k, node, depth)
    else:
      # why this short extension node have no
      # child and still valid when we reconstruct
      # the trie on the other side?
      # a bug in hexary trie algo?
      # or a bug in nim hexary trie implementation?
      writeExtensionNode(wb, k, depth, node)
  of 17:
    let branchMask = rlpListToBitmask(nodeRlp)
    writeBranchNode(wb, branchMask, depth, node)

    for i in 0..<16:
      if branchMask.branchMaskBitIsSet(i):
        var branch = nodeRlp.listElem(i)
        let nextLookup = branch.getNode
        writeShortNode(wb, nextLookup, depth + 1)

    # contrary to yellow paper spec,
    # the 17th elem never exist in reality.
    # block witness spec also omit it.
    # probably a flaw in hexary trie design
    # 17th elem should always empty
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase, "Bad Short Node")

proc getBranchRecurseAux(wb: var WitnessBuilder, node: openArray[byte], path: NibblesSeq, depth: int) =
  var nodeRlp = rlpFromBytes node
  if not nodeRlp.hasData or nodeRlp.isEmpty: return

  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    let sharedNibbles = sharedPrefixLen(path, k)
    if sharedNibbles == k.len:
      let value = nodeRlp.listElem(1)
      if not isLeaf:
        # ExtensionNodeType
        writeExtensionNode(wb, k, depth, node)
        let nextLookup = value.getNode
        getBranchRecurseAux(wb, nextLookup, path.slice(sharedNibbles), depth + sharedNibbles)
      else:
        # AccountNodeType
        writeAccountNode(wb, value.toBytes.decode(Account), k, node, depth)
    else:
      # this is a potential branch for multiproof
      writeHashNode(wb, keccak(node).data)
  of 17:
    let branchMask = rlpListToBitmask(nodeRlp)
    writeBranchNode(wb, branchMask, depth, node)

    let notLeaf = path.len != 0
    for i in 0..<16:
      if branchMask.branchMaskBitIsSet(i):
        var branch = nodeRlp.listElem(i)
        if notLeaf and i == path[0].int:
          let nextLookup = branch.getNode
          getBranchRecurseAux(wb, nextLookup, path.slice(1), depth + 1)
        else:
          if branch.isList:
            let nextLookup = branch.getNode
            writeShortNode(wb, nextLookup, depth + 1)
          else:
            # this is a potential branch for multiproof
            writeHashNode(wb, branch.expectHash)

    # 17th elem should always empty
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc getBranchRecurse*(wb: var WitnessBuilder; key: openArray[byte]): seq[byte] =
  var node = wb.db.get(wb.root.data)
  getBranchRecurseAux(wb, node, initNibbleRange(key), 0)
  result = wb.output.getOutput(seq[byte])

proc getBranchStack*(wb: WitnessBuilder; key: openArray[byte]): string =
  var
    node = wb.db.get(wb.root.data)
    stack = @[(node, initNibbleRange(key))]

  result.add node.toHex
  while stack.len > 0:
    let (node, path) = stack.pop()
    if node.len == 0: continue
    var nodeRlp = rlpFromBytes node

    case nodeRlp.listLen
    of 2:
      let (isLeaf, k) = nodeRlp.extensionNodeKey
      let sharedNibbles = sharedPrefixLen(path, k)
      if sharedNibbles == k.len:
        let value = nodeRlp.listElem(1)
        if not isLeaf:
          let nextLookup = value.getNode
          stack.add((nextLookup, path.slice(sharedNibbles)))
          result.add nextLookup.toHex
    of 17:
      if path.len != 0:
        var branch = nodeRlp.listElem(path[0].int)
        if not branch.isEmpty:
          let nextLookup = branch.getNode
          stack.add((nextLookup, path.slice(1)))
          result.add nextLookup.toHex
    else:
      raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc getBranch*(wb: WitnessBuilder; key: openArray[byte]): seq[seq[byte]] =
  var
    node = wb.db.get(wb.root.data)
    stack = @[(node, initNibbleRange(key))]

  result.add node
  while stack.len > 0:
    let (node, path) = stack.pop()
    if node.len == 0: continue
    var nodeRlp = rlpFromBytes node

    case nodeRlp.listLen
    of 2:
      let (isLeaf, k) = nodeRlp.extensionNodeKey
      let sharedNibbles = sharedPrefixLen(path, k)
      if sharedNibbles == k.len:
        let value = nodeRlp.listElem(1)
        if not isLeaf:
          let nextLookup = value.getNode
          stack.add((nextLookup, path.slice(sharedNibbles)))
          result.add nextLookup
    of 17:
      if path.len != 0:
        var branch = nodeRlp.listElem(path[0].int)
        if not branch.isEmpty:
          let nextLookup = branch.getNode
          stack.add((nextLookup, path.slice(1)))
          result.add nextLookup
    else:
      raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc buildWitness*(wb: var WitnessBuilder; key: openArray[byte]) =
  var
    node = wb.db.get(wb.root.data)
    stack = @[(node, initNibbleRange(key))]

  while stack.len > 0:
    let (node, path) = stack.pop()
    if node.len == 0: continue
    var nodeRlp = rlpFromBytes node

    case nodeRlp.listLen
    of 2:
      let (isLeaf, k) = nodeRlp.extensionNodeKey
      let sharedNibbles = sharedPrefixLen(path, k)
      if sharedNibbles == k.len:
        let value = nodeRlp.listElem(1)
        if not isLeaf:
          let nextLookup = value.getNode
          stack.add((nextLookup, path.slice(sharedNibbles)))
    of 17:
      if path.len != 0:
        var branch = nodeRlp.listElem(path[0].int)
        if not branch.isEmpty:
          let nextLookup = branch.getNode
          stack.add((nextLookup, path.slice(1)))
    else:
      raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")
