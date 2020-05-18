import
  stew/[byteutils, endians2], json, strutils,
  nimcrypto/[keccak, hash], eth/[common, rlp],
  eth/trie/[trie_defs, nibbles, db],
  ./witness_types, ../nimbus/constants,
  ../nimbus/db/storage_types, ./multi_keys

type
  DB = TrieDatabaseRef

  WitnessBuilder* = object
    db*: DB
    root: KeccakHash
    flags: WitnessFlags
    node: JsonNode
    jStack: seq[JsonNode]

  StackElem = object
    node: seq[byte]
    parentGroup: Group
    keys: MultikeysRef
    depth: int
    storageMode: bool

proc initWitnessBuilder*(db: DB, rootHash: KeccakHash, flags: WitnessFlags = {}): WitnessBuilder =
  result.db = db
  result.root = rootHash
  result.flags = flags
  result.node = newJObject()
  result.jStack = @[]

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

proc writeByte(wb: var WitnessBuilder, x: byte, name: string) =
  wb.node[name] = newJString("0x" & toHex(x.int, 2))

proc write(wb: var WitnessBuilder, x: openArray[byte], name: string) =
  wb.node[name] = newJString("0x" & toHex(x))

proc write(wb: var WitnessBuilder, a, b: byte, name: string) =
  wb.node[name] = newJString("0x" & toHex(a.int, 2) & toHex(b.int, 2))

proc write(wb: var WitnessBuilder, x: bool, name: string) =
  wb.node[name] = newJBool(x)

proc pushArray(wb: var WitnessBuilder, name: string) =
  var node = newJArray()
  wb.node[name] = node
  wb.jStack.add wb.node
  wb.node = node

proc pushObject(wb: var WitnessBuilder, name: string) =
  var node = newJObject()
  wb.node[name] = node
  wb.jStack.add wb.node
  wb.node = node

proc addObject(wb: var WitnessBuilder) =
  var node = newJObject()
  wb.node.add node
  wb.jStack.add wb.node
  wb.node = node

proc pop(wb: var WitnessBuilder) =
  wb.node = wb.jStack.pop()

proc writeU32Impl(wb: var WitnessBuilder, x: uint32, name: string) =
  let y = toBytesBE(x)
  wb.node[name] = newJString("0x" & toHex(y))

template writeU32(wb: var WitnessBuilder, x: untyped, name: string) =
  wb.writeU32Impl(uint32(x), name)

template writeByte(wb: var WitnessBuilder, x: untyped, name: string) =
  writeByte(wb, byte(x), name)

proc writeUVarint[T](wb: var WitnessBuilder, x: T, name: string) =
  # LEB128 varint encoding
  var data: array[50, byte]
  var len = 0

  template writeByte(x) =
    data[len] = x.byte
    inc len

  var value = x
  while true:
    when T is UInt256:
      var b = value.truncate(int) and 0x7F # low order 7 bits of value
    else:
      var b = value and 0x7F # low order 7 bits of value
    value = value shr 7
    if value != 0:         # more bytes to come
      b = b or 0x80        # set high order bit of b
    writeByte(b)
    if value == 0: break

  wb.write(data.toOpenArray(0, len-1), name)

template writeUVarint32(wb: var WitnessBuilder, x: untyped, name: string) =
  wb.writeUVarint(uint32(x), name)

proc writeNibbles(wb: var WitnessBuilder; n: NibblesSeq) =
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

  wb.writeByte(nibblesLen, "nibblesLen")
  wb.write(bytes.toOpenArray(0, numBytes-1), "nibbles")

proc writeExtensionNode(wb: var WitnessBuilder, n: NibblesSeq, depth: int, node: openArray[byte]) =
  wb.addObject()
  wb.writeByte(ExtensionNodeType, "nodeType")
  wb.writeNibbles(n)
  wb.writeByte(depth, "debugDepth")
  wb.write(keccak(node).data, "debugHash")
  wb.pop()

proc writeBranchNode(wb: var WitnessBuilder, mask: uint, depth: int, node: openArray[byte]) =
  doAssert mask.branchMaskBitIsSet(16) == false

  wb.addObject()
  wb.writeByte(BranchNodeType, "nodeType")
  wb.write(byte((mask shr 8) and 0xFF), byte(mask and 0xFF), "mask")
  wb.writeByte(depth, "debugDepth")
  wb.write(keccak(node).data, "debugHash")
  wb.pop()

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte]) =
  wb.addObject()
  wb.writeByte(HashNodeType, "nodeType")
  wb.write(node, "data")
  wb.pop()

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte], name: string) =
  wb.pushObject(name)
  wb.writeByte(HashNodeType, "nodeType")
  wb.write(node, "data")
  wb.pop()

proc getBranchRecurse(wb: var WitnessBuilder, z: var StackElem)

proc writeByteCode(wb: var WitnessBuilder, kd: KeyData, acc: Account) =
  if not kd.codeTouched:
    # the account have code but not touched by the EVM
    # in current block execution
    wb.writeByte(CodeUntouched, "codeType")
    let code = get(wb.db, contractHashKey(acc.codeHash).toOpenArray)
    if wfEIP170 in wb.flags and code.len > EIP170_CODE_SIZE_LIMIT:
      raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
    wb.writeUVarint32(code.len, "codeLen")
    wb.writeHashNode(acc.codeHash.data, "codeHash")
    # no need to write 'code' here
    return

  wb.writeByte(CodeTouched, "codeType")
  if acc.codeHash == blankStringHash:
    # no code
    wb.writeUVarint32(0'u32, "codeLen")
    return

  # the account have code and the EVM use it
  let code = get(wb.db, contractHashKey(acc.codeHash).toOpenArray)
  if wfEIP170 in wb.flags and code.len > EIP170_CODE_SIZE_LIMIT:
    raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
  wb.writeUVarint32(code.len, "codeLen")
  wb.write(code, "code")

proc writeStorage(wb: var WitnessBuilder, kd: KeyData, acc: Account) =
  wb.pushArray("storage")
  if kd.storageKeys.isNil:
    # the account have storage but not touched by EVM
    wb.writeHashNode(acc.storageRoot.data)
  elif acc.storageRoot != emptyRlpHash:
    # the account have storage and the EVM use it
    var zz = StackElem(
      node: wb.db.get(acc.storageRoot.data),
      parentGroup: kd.storageKeys.initGroup(),
      keys: kd.storageKeys,
      depth: 0,          # set depth to zero
      storageMode: true  # switch to storage mode
    )
    getBranchRecurse(wb, zz)
  else:
    # no storage at all
    wb.writeHashNode(emptyRlpHash.data)
  wb.pop()

proc writeAccountNode(wb: var WitnessBuilder, kd: KeyData, acc: Account, node: openArray[byte], depth: int) =
  wb.addObject()
  wb.writeByte(AccountNodeType, "nodeType")

  var accountType = if acc.codeHash == blankStringHash and acc.storageRoot == emptyRlpHash: SimpleAccountType
                    else: ExtendedAccountType

  wb.writeByte(accountType, "accountType")
  wb.write(kd.address, "address")
  wb.writeUVarint(acc.balance, "balance")
  wb.writeUVarint(acc.nonce, "nonce")

  if accountType != SimpleAccountType:
    wb.writeByteCode(kd, acc)
    wb.writeStorage(kd, acc)

  wb.writeByte(depth, "debugDepth")
  wb.write(keccak(node).data, "debugHash")
  wb.pop()

proc writeAccountStorageLeafNode(wb: var WitnessBuilder, key: openArray[byte], val: UInt256, node: openArray[byte], depth: int) =
  wb.addObject()
  wb.writeByte(StorageLeafNodeType, "nodeType")
  wb.write(key, "key")
  wb.write(val.toBytesBE, "value")
  wb.writeByte(depth, "debugDepth")
  wb.write(keccak(node).data, "debugHash")
  wb.pop()

proc getBranchRecurse(wb: var WitnessBuilder, z: var StackElem) =
  if z.node.len == 0: return
  var nodeRlp = rlpFromBytes z.node

  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    let mg = groups(z.keys, z.depth, k, z.parentGroup)

    if not mg.match:
      # return immediately if there is no match
      writeHashNode(wb, keccak(z.node).data)
      return

    let value = nodeRlp.listElem(1)
    if not isLeaf:
      # recursion will go deeper depend on the common-prefix length nibbles
      writeExtensionNode(wb, k, z.depth, z.node)
      var zz = StackElem(
        node: value.getNode,
        parentGroup: mg.group,
        keys: z.keys,
        depth: z.depth + k.len, # increase the depth by k.len
        storageMode: z.storageMode
      )
      getBranchRecurse(wb, zz)
      return

    # there should be only one match
    let kd = z.keys.visitMatch(mg, z.depth, k)
    if z.storageMode:
      doAssert(kd.storageMode)
      writeAccountStorageLeafNode(wb, kd.storageSlot, value.toBytes.decode(UInt256), z.node, z.depth)
    else:
      doAssert(not kd.storageMode)
      writeAccountNode(wb, kd, value.toBytes.decode(Account), z.node, z.depth)

  of 17:
    let branchMask = rlpListToBitmask(nodeRlp)
    writeBranchNode(wb, branchMask, z.depth, z.node)

    # if there is a match in any branch elem
    # 1st to 16th, the recursion will go deeper
    # by one nibble
    doAssert(z.depth != 64) # notLeaf or path.len == 0

    let path = groups(z.keys, z.parentGroup, z.depth)
    for i in nonEmpty(branchMask):
      let branch = nodeRlp.listElem(i)
      if branchMaskBitIsSet(path.mask, i):
        # it is a match between multikeys and Branch Node elem
        var zz = StackElem(
          node: branch.getNode,
          parentGroup: path.groups[i],
          keys: z.keys,
          depth: z.depth + 1, # increase the depth by one
          storageMode: z.storageMode
        )
        getBranchRecurse(wb, zz)
        continue

      if branch.isList:
        # short node appear in yellow paper
        # but never in the actual ethereum state trie
        # an rlp encoded ethereum account will have length > 32 bytes
        # block witness spec silent about this
        doAssert(false, "Short node should not exist in block witness")
      else:
        # if branch elem not empty and not a match, emit hash
        writeHashNode(wb, branch.expectHash)

    # 17th elem should always empty
    # 17th elem appear in yellow paper but never in
    # the actual ethereum state trie
    # the 17th elem also not included in block witness spec
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc buildWitness*(wb: var WitnessBuilder, keys: MultikeysRef): string =

  # witness version
  wb.writeByte(BlockWitnessVersion, "version")

  # one or more trees

  # we only output one tree
  wb.writeByte(MetadataNothing, "metadata")

  wb.write(wb.root.data, "rootHash")
  wb.write(false, "error")

  wb.pushArray("tree")

  var z = StackElem(
    node: @(wb.db.get(wb.root.data)),
    parentGroup: keys.initGroup(),
    keys: keys,
    depth: 0,
    storageMode: false
  )
  getBranchRecurse(wb, z)

  wb.pop()
  result = wb.node.pretty()
