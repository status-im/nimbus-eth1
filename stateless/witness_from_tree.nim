import
  stew/[byteutils, endians2],
  nimcrypto/[keccak, hash], eth/rlp,
  eth/trie/[trie_defs, nibbles, db],
  faststreams/output_stream,
  ./witness_types

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
  else: get(db, elem.expectHash)

proc rlpListToBitmask(r: var Rlp): uint =
  var i = 0
  for branch in r:
    if not branch.isEmpty:
      result.setBranchMaskBit(i)
    inc i
  r.position = 0

proc writeNibbles(wb: var WitnessBuilder; n: NibblesSeq) =
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

  # write nibblesLen
  wb.output.append(nibblesLen.byte)
  # write nibbles
  wb.output.append(bytes.toOpenArray(0, numBytes-1))

proc writeExtensionNode(wb: var WitnessBuilder, n: NibblesSeq) =
  # write type
  wb.output.append(ExtensionNodeType.byte)
  # write nibbles
  wb.writeNibbles(n)

proc writeBranchNode(wb: var WitnessBuilder, mask: uint) =
  # write type
  if mask.branchMaskBitIsSet(16):
    wb.output.append(Branch17NodeType.byte)
  else:
    wb.output.append(BranchNodeType.byte)
  # write branch mask
  wb.output.append(((mask shr 8) and 0xFF).byte)
  wb.output.append((mask and 0xFF).byte)

proc writeAccountNode(wb: var WitnessBuilder, node: openArray[byte]) =
  # write type
  wb.output.append(AccountNodeType.byte)
  wb.output.append(toBytesLe(node.len.uint32))
  wb.output.append(node)

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte]) =
  # write type
  wb.output.append(HashNodeType.byte)
  wb.output.append(node)

proc getBranchRecurseAux(wb: var WitnessBuilder; db: DB, node: openArray[byte], path: NibblesSeq) =
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
        writeExtensionNode(wb, k)
        let nextLookup = value.getNode
        getBranchRecurseAux(wb, db, nextLookup, path.slice(sharedNibbles))
      else:
        # AccountNodeType
        writeAccountNode(wb, value.toBytes)
    else:
      writeHashNode(wb, keccak(node).data)
  of 17:
    let branchMask = rlpListToBitmask(nodeRlp)
    writeBranchNode(wb, branchMask)

    if path.len != 0:
      for i in 0..<16:
        if branchMask.branchMaskBitIsSet(i):
          var branch = nodeRlp.listElem(i)
          if i == path[0].int:
            let nextLookup = branch.getNode
            getBranchRecurseAux(wb, db, nextLookup, path.slice(1))
          else:
            writeHashNode(wb, branch.expectHash)
    else:
      for i in 0..<16:
        if branchMask.branchMaskBitIsSet(i):
          var branch = nodeRlp.listElem(i)
          writeHashNode(wb, branch.expectHash)

    # put 17th elem
    var lastElem = nodeRlp.listElem(16)
    if not lastElem.isEmpty:
      if path.len == 0:
        writeAccountNode(wb, lastElem.toBytes)
      else:
        writeHashNode(wb, lastElem.toBytes)
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc getBranchRecurse*(wb: var WitnessBuilder; key: openArray[byte]): seq[byte] =
  var node = wb.db.get(wb.root.data)
  getBranchRecurseAux(wb, wb.db, node, initNibbleRange(key))
  shallowCopy(result, wb.output.getOutput(seq[byte]))

proc getBranchStack*(self: WitnessBuilder; key: openArray[byte]): string =
  var
    node = self.db.get(self.root.data)
    stack = @[(node, initNibbleRange(key))]
    db = self.db

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

#[
proc hexPrefixDecode*(r: openArray[byte]): tuple[isLeaf: bool, nibbles: NibblesSeq] =
  result.nibbles = initNibbleRange(r)
  if r.len > 0:
    result.isLeaf = (r[0] and 0x20) != 0
    let hasOddLen = (r[0] and 0x10) != 0
    result.nibbles.ibegin = 2 - int(hasOddLen)
  else:
    result.isLeaf = false

proc sharedPrefixLen*(lhs, rhs: NibblesSeq): int =
  result = 0
  while result < lhs.len and result < rhs.len:
    if lhs[result] != rhs[result]: break
    inc result
]#
proc getBranch*(self: WitnessBuilder; key: openArray[byte]): seq[seq[byte]] =
  var
    node = self.db.get(self.root.data)
    stack = @[(node, initNibbleRange(key))]
    db = self.db

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

proc buildWitness*(self: var WitnessBuilder; key: openArray[byte]) =
  var
    node = self.db.get(self.root.data)
    stack = @[(node, initNibbleRange(key))]
    db = self.db

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

