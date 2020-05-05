import
  stew/[byteutils, endians2],
  nimcrypto/[keccak, hash], eth/[common, rlp],
  eth/trie/[trie_defs, nibbles, db],
  faststreams/output_stream,
  ./witness_types, ../nimbus/constants,
  ../nimbus/db/storage_types, ./multi_keys

type
  DB = TrieDatabaseRef

  WitnessBuilder* = object
    db*: DB
    root: KeccakHash
    output: OutputStream
    flags: WitnessFlags

  StackElem = object
    node: seq[byte]
    parentGroup: Group
    keys: MultikeysRef
    depth: int
    storageMode: bool

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
  else: @(get(wb.db, elem.expectHash))

proc rlpListToBitmask(r: var Rlp): uint =
  var i = 0
  for branch in r:
    if not branch.isEmpty:
      result.setBranchMaskBit(i)
    inc i
  r.position = 0

template write(wb: var WitnessBuilder, x: untyped) =
  wb.output.append(x)

proc writeU32Impl(wb: var WitnessBuilder, x: uint32) =
  wb.write(toBytesBE(x))

template writeU32(wb: var WitnessBuilder, x: untyped) =
  wb.writeU32Impl(uint32(x))

template writeByte(wb: var WitnessBuilder, x: untyped) =
  wb.write(byte(x))

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
    wb.writeByte(nibblesLen)
  # write nibbles
  wb.write(bytes.toOpenArray(0, numBytes-1))

proc writeExtensionNode(wb: var WitnessBuilder, n: NibblesSeq, depth: int, node: openArray[byte]) =
  # write type
  wb.writeByte(ExtensionNodeType)
  # write nibbles
  wb.writeNibbles(n)

  when defined(debugDepth):
    wb.writeByte(depth)

  when defined(debugHash):
    wb.write(keccak(node).data)

proc writeBranchNode(wb: var WitnessBuilder, mask: uint, depth: int, node: openArray[byte]) =
  # write type
  # branch node 17th elem should always empty
  doAssert mask.branchMaskBitIsSet(16) == false
  wb.writeByte(BranchNodeType)
  # write branch mask
  # countOnes(branch mask) >= 2 and <= 16
  wb.writeByte((mask shr 8) and 0xFF)
  wb.writeByte(mask and 0xFF)

  when defined(debugDepth):
    wb.writeByte(depth)

  when defined(debugHash):
    wb.write(keccak(node).data)

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte]) =
  # write type
  wb.writeByte(HashNodeType)
  wb.write(node)

proc getBranchRecurse(wb: var WitnessBuilder, z: var StackElem) {.raises: [ContractCodeError, IOError, Defect, CatchableError, Exception].}

proc writeAccountNode(wb: var WitnessBuilder, kd: KeyData, acc: Account, nibbles: NibblesSeq,
  node: openArray[byte], depth: int) {.raises: [ContractCodeError, IOError, Defect, CatchableError, Exception].} =

  # write type
  wb.writeByte(AccountNodeType)

  when defined(debugHash):
    wb.writeU32(node.len)
    wb.write(node)

  when defined(debugDepth):
    wb.writeByte(depth)

  doAssert(nibbles.len == 64 - depth)
  var accountType = if acc.codeHash == blankStringHash and acc.storageRoot == emptyRlpHash: SimpleAccountType
                    else: ExtendedAccountType

  if not kd.codeTouched:
    accountType = CodeUntouched

  wb.writeByte(accountType)
  wb.writeNibbles(nibbles, false)
  wb.write(kd.address)
  wb.write(acc.balance.toBytesBE)
  wb.write(acc.nonce.u256.toBytesBE)

  if accountType != SimpleAccountType:
    if not kd.codeTouched:
      wb.writeHashNode(acc.codeHash.data)
      let code = get(wb.db, contractHashKey(acc.codeHash).toOpenArray)
      if wfEIP170 in wb.flags and code.len > EIP170_CODE_SIZE_LIMIT:
        raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
      wb.writeU32(code.len)
      # no code here
    elif acc.codeHash != blankStringHash:
      let code = get(wb.db, contractHashKey(acc.codeHash).toOpenArray)
      if wfEIP170 in wb.flags and code.len > EIP170_CODE_SIZE_LIMIT:
        raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
      wb.writeU32(code.len)
      wb.write(code)
    else:
      wb.writeU32(0'u32)

    if kd.storageKeys.isNil:
      # we have storage but not touched  by EVM
      wb.writeHashNode(acc.storageRoot.data)
    elif acc.storageRoot != emptyRlpHash:
      var zz = StackElem(
        node: wb.db.get(acc.storageRoot.data),
        parentGroup: kd.storageKeys.initGroup(),
        keys: kd.storageKeys,
        depth: 0,          # reset depth
        storageMode: true  # switch to storage mode
      )
      getBranchRecurse(wb, zz)
    else:
      wb.writeHashNode(emptyRlpHash.data)

  #0x00 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32>
  #0x01 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32> bytecode:<Bytecode> storage:<Tree_Node(0,1)>
  #0x02 pathnibbles:<Nibbles(64-d)> address:<Address> balance:<Bytes32> nonce:<Bytes32> codehash:<Bytes32> codesize:<U32> storage:<Account_Storage_Tree_Node(0)>

proc writeAccountStorageLeafNode(wb: var WitnessBuilder, key: openArray[byte], val: UInt256, nibbles: NibblesSeq, node: openArray[byte], depth: int) =
  wb.writeByte(StorageLeafNodeType)

  when defined(debugHash):
    wb.writeU32(node.len)
    wb.write(node)

  when defined(debugDepth):
    wb.writeByte(depth)

  doAssert(nibbles.len == 64 - depth)
  wb.writeNibbles(nibbles, false)

  wb.write(key)
  wb.write(val.toBytesBE)

  #<Storage_Leaf_Node(d<65)> := pathnibbles:<Nibbles(64-d))> key:<Bytes32> val:<Bytes32>

proc getBranchRecurse(wb: var WitnessBuilder, z: var StackElem) =
  if z.node.len == 0: return
  var nodeRlp = rlpFromBytes z.node

  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    var match = false
    # only zero or one group can match the path
    # but if there is a match, it can be in any position
    # 1st, 2nd, or max 3rd position
    # recursion will go deeper depend on the common-prefix length nibbles
    for mg in groups(z.keys, z.depth, k, z.parentGroup):
      if not mg.match: continue
      doAssert(match == false) # should be only one match
      match = true
      let value = nodeRlp.listElem(1)
      if not isLeaf:
        # ExtensionNodeType
        writeExtensionNode(wb, k, z.depth, z.node)
        var zz = StackElem(
          node: value.getNode,
          parentGroup: mg.group,
          keys: z.keys,
          depth: z.depth + k.len,
          storageMode: z.storageMode
        )
        getBranchRecurse(wb, zz)
      else:
        # this should be only one match
        # if there is more than one match
        # it means we encounter a rogue address
        for kd in keyDatas(z.keys, mg.group):
          if not match(kd, k, z.depth): continue # this is the rogue address
          kd.visited = true
          if z.storageMode:
            doAssert(kd.storageMode)
            writeAccountStorageLeafNode(wb, kd.storageSlot, value.toBytes.decode(UInt256), k, z.node, z.depth)
          else:
            doAssert(not kd.storageMode)
            writeAccountNode(wb, kd, value.toBytes.decode(Account), k, z.node, z.depth)
    if not match:
      writeHashNode(wb, keccak(z.node).data)
  of 17:
    let branchMask = rlpListToBitmask(nodeRlp)
    writeBranchNode(wb, branchMask, z.depth, z.node)
    let path = groups(z.keys, z.parentGroup, z.depth)

    # if there is a match in any branch elem
    # 1st to 16th, the recursion will go deeper
    # by one nibble
    let notLeaf = z.depth != 63 # path.len == 0
    for i in 0..<16:
      if not branchMask.branchMaskBitIsSet(i): continue
      var branch = nodeRlp.listElem(i)
      if notLeaf and branchMaskBitIsSet(path.mask, i):
        var zz = StackElem(
          node: branch.getNode,
          parentGroup: path.groups[i],
          keys: z.keys,
          depth: z.depth + 1,
          storageMode: z.storageMode
        )
        getBranchRecurse(wb, zz)
      else:
        if branch.isList:
          doAssert(false, "Short node should not exist in block witness")
        else:
          # this is a potential branch for multiproof
          writeHashNode(wb, branch.expectHash)

    # 17th elem should always empty
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc buildWitness*(wb: var WitnessBuilder, keys: MultikeysRef): seq[byte]
  {.raises: [ContractCodeError, IOError, Defect, CatchableError, Exception].} =

  # witness version
  wb.writeByte(BlockWitnessVersion)

  # one or more trees

  # we only output one tree
  wb.writeByte(MetadataNothing)

  var z = StackElem(
    node: @(wb.db.get(wb.root.data)),
    parentGroup: keys.initGroup(),
    keys: keys,
    depth: 0,
    storageMode: false
  )
  getBranchRecurse(wb, z)

  # result
  result = wb.output.getOutput(seq[byte])
