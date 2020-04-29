import
  stew/[byteutils, endians2],
  nimcrypto/[keccak, hash], eth/[common, rlp],
  eth/trie/[trie_defs, nibbles, db],
  faststreams/output_stream,
  ./witness_types, ../nimbus/constants,
  ../nimbus/db/storage_types

type
  DB = TrieDatabaseRef

  WitnessBuilder* = object
    db*: DB
    root: KeccakHash
    output: OutputStream
    flags: WitnessFlags

proc initWitnessBuilder*(db: DB, rootHash: KeccakHash, flags: WitnessFlags = {}): WitnessBuilder =
  result.db = db
  result.root = rootHash
  result.output = memoryOutput().s
  result.flags = flags

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
  # convert the NibblesSeq into left aligned byte seq
  # perhaps we can optimize it if the NibblesSeq already left aligned
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
  # countOnes(branch mask) >= 2 and <= 16
  wb.output.append(((mask shr 8) and 0xFF).byte)
  wb.output.append((mask and 0xFF).byte)

  when defined(debugDepth):
    wb.output.append(depth.byte)

  when defined(debugHash):
    wb.output.append(keccak(node).data)

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte]) =
  # write type
  wb.output.append(HashNodeType.byte)
  wb.output.append(node)

proc getBranchRecurseAux(wb: var WitnessBuilder, node: openArray[byte], path: NibblesSeq, depth: int, storageMode: bool)

proc writeAccountNode(wb: var WitnessBuilder, acc: Account, nibbles: NibblesSeq, node: openArray[byte], depth: int) =
  # write type
  wb.output.append(AccountNodeType.byte)

  when defined(debugHash):
    wb.writeU32(node.len.uint32)
    wb.output.append(node)

  when defined(debugDepth):
    wb.output.append(depth.byte)

  doAssert(nibbles.len == 64 - depth)
  let accountType = if acc.codeHash == blankStringHash and acc.storageRoot == emptyRlpHash: SimpleAccountType
                    else: ExtendedAccountType

  wb.output.append(accountType.byte)
  wb.writeNibbles(nibbles, false)
  # TODO: where the address come from?
  # single proof is easy, but multiproof will be harder
  # concat the path and then look into LUT?
  # wb.output.append(acc.address)
  wb.output.append(acc.balance.toBytesBE)
  wb.output.append(acc.nonce.u256.toBytesBE)

  if accountType == ExtendedAccountType:
    if acc.codeHash != blankStringHash:
      let code = get(wb.db, contractHashKey(acc.codeHash).toOpenArray)
      if wfEIP170 in wb.flags and code.len > EIP170_CODE_SIZE_LIMIT:
        raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
      wb.writeU32(code.len.uint32)
      wb.output.append(code)
    else:
      wb.writeU32(0'u32)

    if acc.storageRoot != emptyRlpHash:
      # switch to account mode
      var node = wb.db.get(acc.storageRoot.data)
      var key = keccak(0.u256.toByteArrayBE)
      getBranchRecurseAux(wb, node, initNibbleRange(key.data), 0, true)
    else:
      wb.writeHashNode(emptyRlpHash.data)

  #0x00 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32>
  #0x01 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32> bytecode:<Bytecode> storage:<Tree_Node(0,1)>

proc writeAccountStorageLeafNode(wb: var WitnessBuilder, val: UInt256, nibbles: NibblesSeq, node: openArray[byte], depth: int) =
  wb.output.append(StorageLeafNodeType.byte)
  doAssert(nibbles.len == 64 - depth)
  wb.writeNibbles(nibbles, false)

  # TODO: write key
  # wb.output.append(key.toByteArrayBE)
  wb.output.append(val.toByteArrayBE)

  #<Storage_Leaf_Node(d<65)> := pathnibbles:<Nibbles(64-d))> key:<Bytes32> val:<Bytes32>

proc writeShortNode(wb: var WitnessBuilder, node: openArray[byte], depth: int, storageMode: bool) =
  var nodeRlp = rlpFromBytes node
  if not nodeRlp.hasData or nodeRlp.isEmpty: return
  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    if isLeaf:
      if storageMode:
        let val = nodeRlp.listElem(1).toBytes.decode(UInt256)
        writeAccountStorageLeafNode(wb, val, k, node, depth)
      else:
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
        writeShortNode(wb, nextLookup, depth + 1, storageMode)

    # contrary to yellow paper spec,
    # the 17th elem never exist in reality.
    # block witness spec also omit it.
    # probably a flaw in hexary trie design
    # 17th elem should always empty
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase, "Bad Short Node")

proc getBranchRecurseAux(wb: var WitnessBuilder, node: openArray[byte], path: NibblesSeq, depth: int, storageMode: bool) =
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
        getBranchRecurseAux(wb, nextLookup, path.slice(sharedNibbles), depth + sharedNibbles, storageMode)
      else:
        # AccountNodeType
        if storageMode:
          writeAccountStorageLeafNode(wb, value.toBytes.decode(UInt256), k, node, depth)
        else:
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
          getBranchRecurseAux(wb, nextLookup, path.slice(1), depth + 1, storageMode)
        else:
          if branch.isList:
            let nextLookup = branch.getNode
            writeShortNode(wb, nextLookup, depth + 1, storageMode)
          else:
            # this is a potential branch for multiproof
            writeHashNode(wb, branch.expectHash)

    # 17th elem should always empty
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc buildWitness*(wb: var WitnessBuilder; address: EthAddress, withVersion: bool = true): seq[byte] =
  # witness version
  wb.output.append(BlockWitnessVersion.byte)

  # one or more trees

  # we only output one tree
  wb.output.append(MetadataNothing.byte)
  let key = keccak(address)
  var node = wb.db.get(wb.root.data)
  getBranchRecurseAux(wb, node, initNibbleRange(key.data), 0, false)

  # result
  result = wb.output.getOutput(seq[byte])
