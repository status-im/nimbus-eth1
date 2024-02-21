# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  stew/[byteutils, endians2],
  eth/[common, rlp],
  eth/trie/[trie_defs, nibbles],
  faststreams/outputs,
  ../nimbus/constants,
  ../nimbus/db/[core_db, storage_types],
  "."/[multi_keys, witness_types]

type
  WitnessBuilder* = object
    db*: CoreDbRef
    root: KeccakHash
    output: OutputStream
    flags: WitnessFlags

  StackElem = object
    node: seq[byte]
    parentGroup: Group
    keys: MultiKeysRef
    depth: int
    storageMode: bool

proc initWitnessBuilder*(db: CoreDbRef, rootHash: KeccakHash, flags: WitnessFlags = {}): WitnessBuilder =
  result.db = db
  result.root = rootHash
  result.output = memoryOutput().s
  result.flags = flags

template extensionNodeKey(r: Rlp): auto =
  hexPrefixDecode r.listElem(0).toBytes

proc expectHash(r: Rlp): seq[byte] {.gcsafe, raises: [RlpError].} =
  result = r.toBytes
  if result.len != 32:
    raise newException(RlpTypeMismatch,
      "RLP expected to be a Keccak hash value, but has an incorrect length")

template getNode(elem: untyped): untyped =
  if elem.isList: @(elem.rawData)
  else: @(wb.db.kvt.get elem.expectHash)

proc rlpListToBitmask(r: var Rlp): uint {.gcsafe, raises: [RlpError].} =
  # only bit 1st to 16th are valid
  # the 1st bit is the rightmost bit
  var i = 0
  for branch in r:
    if not branch.isEmpty:
      result.setBranchMaskBit(i)
    inc i
  r.position = 0

template write(wb: var WitnessBuilder, x: untyped) =
  wb.output.write(x)

when defined(debugHash):
  proc writeU32Impl(wb: var WitnessBuilder, x: uint32) =
    wb.write(toBytesBE(x))

  template writeU32(wb: var WitnessBuilder, x: untyped) =
    wb.writeU32Impl(uint32(x))

template writeByte(wb: var WitnessBuilder, x: untyped) =
  wb.write(byte(x))

proc writeUVarint(wb: var WitnessBuilder, x: SomeUnsignedInt)
    {.gcsafe, raises: [IOError].} =
  # LEB128 varint encoding
  var value = x
  while true:
    var b = value and 0x7F # low order 7 bits of value
    value = value shr 7
    if value != 0:         # more bytes to come
      b = b or 0x80        # set high order bit of b
    wb.writeByte(b)
    if value == 0: break

template writeUVarint32(wb: var WitnessBuilder, x: untyped) =
  wb.writeUVarint(uint32(x))

proc writeUVarint(wb: var WitnessBuilder, x: UInt256)
    {.gcsafe, raises: [IOError].} =
  # LEB128 varint encoding
  var value = x
  while true:
    # we don't truncate to byte here, int will be faster
    var b = value.truncate(int) and 0x7F # low order 7 bits of value
    value = value shr 7
    if value.isZero.not:         # more bytes to come
      b = b or 0x80        # set high order bit of b
    wb.writeByte(b)
    if value.isZero: break

proc writeNibbles(wb: var WitnessBuilder; n: NibblesSeq, withLen: bool = true)
    {.gcsafe, raises: [IOError].} =
  # convert the NibblesSeq into left aligned byte seq
  # perhaps we can optimize it if the NibblesSeq already left aligned
  let nibblesLen = n.len
  let numBytes = nibblesLen div 2 + nibblesLen mod 2
  var bytes: array[32, byte]
  doAssert(nibblesLen >= 1 and nibblesLen <= 64)
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

proc writeExtensionNode(wb: var WitnessBuilder, n: NibblesSeq, depth: int, node: openArray[byte])
    {.gcsafe, raises: [IOError].} =
  # write type
  wb.writeByte(ExtensionNodeType)
  # write nibbles
  wb.writeNibbles(n)

  when defined(debugDepth):
    wb.writeByte(depth)

  when defined(debugHash):
    wb.write(keccakHash(node).data)

proc writeBranchNode(wb: var WitnessBuilder, mask: uint, depth: int, node: openArray[byte])
    {.gcsafe, raises: [IOError].} =
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
    wb.write(keccakHash(node).data)

proc writeHashNode(wb: var WitnessBuilder, node: openArray[byte], depth: int, storageMode: bool)
    {.gcsafe, raises: [IOError].} =
  # usually a hash node means the recursion will not go deeper
  # and the information can be represented by the hash
  # for chunked witness, a hash node can be a root to another
  # sub-trie in one of the chunks
  wb.writeByte(HashNodeType)
  if depth >= 9 and storageMode and node[0] == 0.byte:
    wb.writeByte(ShortRlpPrefix)
  wb.write(node)

proc writeShortRlp(wb: var WitnessBuilder, node: openArray[byte], depth: int, storageMode: bool)
    {.gcsafe, raises: [IOError].} =
  doAssert(node.len < 32 and storageMode)
  wb.writeByte(HashNodeType)
  wb.writeByte(ShortRlpPrefix)
  wb.writeByte(node.len)
  wb.write(node)

proc getBranchRecurse(wb: var WitnessBuilder, z: var StackElem) {.gcsafe, raises: [CatchableError].}

proc writeByteCode(wb: var WitnessBuilder, kd: KeyData, acc: Account, depth: int)
    {.gcsafe, raises: [IOError,ContractCodeError].} =
  let kvt = wb.db.kvt()
  if not kd.codeTouched:
    # the account have code but not touched by the EVM
    # in current block execution
    wb.writeByte(CodeUntouched)
    let code = kvt.get contractHashKey(acc.codeHash).toOpenArray
    if wfEIP170 in wb.flags and code.len > EIP170_MAX_CODE_SIZE:
      raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
    wb.writeUVarint32(code.len)
    wb.writeHashNode(acc.codeHash.data, depth, false)
    # no need to write 'code' here
    return

  wb.writeByte(CodeTouched)
  if acc.codeHash == blankStringHash:
    # no code
    wb.writeUVarint32(0'u32)
    return

  # the account have code and the EVM use it
  let code = kvt.get contractHashKey(acc.codeHash).toOpenArray
  if wfEIP170 in wb.flags and code.len > EIP170_MAX_CODE_SIZE:
    raise newException(ContractCodeError, "code len exceed EIP170 code size limit")
  wb.writeUVarint32(code.len)
  wb.write(code)

proc writeStorage(wb: var WitnessBuilder, kd: KeyData, acc: Account, depth: int)
    {.gcsafe, raises: [CatchableError].} =
  if kd.storageKeys.isNil:
    # the account have storage but not touched by EVM
    wb.writeHashNode(acc.storageRoot.data, depth, true)
  elif acc.storageRoot != emptyRlpHash:
    # the account have storage and the EVM use it
    var zz = StackElem(
      node: wb.db.kvt.get(acc.storageRoot.data),
      parentGroup: kd.storageKeys.initGroup(),
      keys: kd.storageKeys,
      depth: 0,          # set depth to zero
      storageMode: true  # switch to storage mode
    )
    getBranchRecurse(wb, zz)
  else:
    # no storage at all
    wb.writeHashNode(emptyRlpHash.data, depth, true)

proc writeAccountNode(wb: var WitnessBuilder, kd: KeyData, acc: Account,
  node: openArray[byte], depth: int) {.raises: [ContractCodeError, IOError, CatchableError].} =

  # write type
  wb.writeByte(AccountNodeType)

  when defined(debugHash):
    wb.writeU32(node.len)
    wb.write(node)

  when defined(debugDepth):
    wb.writeByte(depth)

  var accountType = if acc.codeHash == blankStringHash and acc.storageRoot == emptyRlpHash: SimpleAccountType
                    else: ExtendedAccountType

  wb.writeByte(accountType)
  wb.write(kd.address)
  wb.writeUVarint(acc.balance)
  wb.writeUVarint(acc.nonce)

  if accountType != SimpleAccountType:
    wb.writeByteCode(kd, acc, depth)
    wb.writeStorage(kd, acc, depth)

  #0x00 address:<Address> balance:<Bytes32> nonce:<Bytes32>
  #0x01 address:<Address> balance:<Bytes32> nonce:<Bytes32> bytecode:<Bytecode> storage:<Tree_Node(0,1)>

proc writeAccountStorageLeafNode(wb: var WitnessBuilder, key: openArray[byte], val: UInt256, node: openArray[byte], depth: int)
    {.gcsafe, raises: [IOError].} =
  wb.writeByte(StorageLeafNodeType)

  when defined(debugHash):
    wb.writeU32(node.len)
    wb.write(node)

  when defined(debugDepth):
    wb.writeByte(depth)

  wb.write(key)
  wb.write(val.toBytesBE)

  #<Storage_Leaf_Node(d<65)> := key:<Bytes32> val:<Bytes32>

proc getBranchRecurse(wb: var WitnessBuilder, z: var StackElem) =
  if z.node.len == 0: return
  if z.node.len < 32:
    writeShortRlp(wb, z.node, z.depth, z.storageMode)
    return

  var nodeRlp = rlpFromBytes z.node

  case nodeRlp.listLen
  of 2:
    let (isLeaf, k) = nodeRlp.extensionNodeKey
    let mg = groups(z.keys, z.depth, k, z.parentGroup)

    if not mg.match:
      # return immediately if there is no match
      writeHashNode(wb, keccakHash(z.node).data, z.depth, z.storageMode)
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
    let kd = z.keys.visitMatch(mg, z.depth)
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
        # it is a match between MultiKeysRef and Branch Node elem
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
        writeShortRlp(wb, branch.rawData, z.depth, z.storageMode)
      else:
        # if branch elem not empty and not a match, emit hash
        writeHashNode(wb, branch.expectHash, z.depth, z.storageMode)

    # 17th elem should always empty
    # 17th elem appear in yellow paper but never in
    # the actual ethereum state trie
    # the 17th elem also not included in block witness spec
    doAssert branchMask.branchMaskBitIsSet(16) == false
  else:
    raise newException(CorruptedTrieDatabase,
                       "HexaryTrie node with an unexpected number of children")

proc buildWitness*(wb: var WitnessBuilder, keys: MultiKeysRef): seq[byte]
  {.raises: [CatchableError].} =

  # witness version
  wb.writeByte(BlockWitnessVersion)

  # one or more trees

  # we only output one big tree here
  # the condition to split the big tree into chunks of sub-tries
  # is not clear in the spec
  wb.writeByte(MetadataNothing)

  var z = StackElem(
    node: @(wb.db.kvt.get(wb.root.data)),
    parentGroup: keys.initGroup(),
    keys: keys,
    depth: 0,          # always start with a zero depth
    storageMode: false # build account witness first
  )
  getBranchRecurse(wb, z)

  # result
  result = wb.output.getOutput(seq[byte])
