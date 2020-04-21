import
  stew/byteutils,
  nimcrypto/[keccak, hash], eth/rlp,
  eth/trie/[trie_defs, nibbles, db],
  faststreams/output_stream,
  ./witness_types

type
  DB = TrieDatabaseRef

  WitnessBuilder* = object
    db*: DB
    root: KeccakHash
    output: ref OutputStream

proc initWitnessBuilder*(db: DB, rootHash: KeccakHash = emptyRlpHash): WitnessBuilder =
  result.db = db
  result.root = rootHash
  result.output = OutputStream.init

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

proc getBranchRecurseAux(db: DB, node: openArray[byte], path: NibblesSeq, output: var string) =
  var nodeRlp = rlpFromBytes node
  if not nodeRlp.hasData or nodeRlp.isEmpty: return

  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    let sharedNibbles = sharedPrefixLen(path, k)
    if sharedNibbles == k.len:
      let value = nodeRlp.listElem(1)
      if not isLeaf:
        let nextLookup = value.getNode
        output.add nextLookup.toHex
        getBranchRecurseAux(db, nextLookup, path.slice(sharedNibbles), output)
  of 17:
    if path.len != 0:
      var branch = nodeRlp.listElem(path[0].int)
      if not branch.isEmpty:
        let nextLookup = branch.getNode
        output.add nextLookup.toHex
        getBranchRecurseAux(db, nextLookup, path.slice(1), output)
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc getBranchRecurse*(self: WitnessBuilder; key: openArray[byte]): string =
  var node = self.db.get(self.root.data)
  result.add node.toHex
  getBranchRecurseAux(self.db, node, initNibbleRange(key), result)

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


proc writeNibbles(self: var WitnessBuilder; n: NibblesSeq) =
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

  self.output.append(bytes.toOpenArray(0, numBytes-1))

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

