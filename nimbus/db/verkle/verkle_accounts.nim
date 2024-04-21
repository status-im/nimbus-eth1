# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/algorithm,
  eth/common,
  std/[times, os],
  stew/[byteutils, endians2], stint,
  ../../evm/interpreter/op_codes,
  "../../../vendor/nim-eth-verkle/eth_verkle"/[
    math,
    tree/tree, 
    tree/operations, 
    tree/commitment
  ],
  "../../../vendor/nim-eth-verkle/constantine/constantine"/[
    serialization/codecs_banderwagon
  ]

type
  ChunkedCode* = seq[byte]
  VerkleTrieRef* = ref object
    root: BranchesNode
  # db: <something>
  # persistcheck: <some-flag>

const
  VersionLeafKey* = 0
  BalanceLeafKey* = 1
  NonceLeafKey* = 2
  CodeKeccakLeafKey* = 3
  CodeSizeLeafKey* = 4

const
  CodeOffset* = UInt256.fromHex("0x100")
  HeaderStorageOffset* = UInt256.fromHex("0x40")
  CodeStorageDelta* = UInt256.fromHex("0x40")
  VerkleNodeWidthLog2* = 8

let one = 1.u256
let twofourty = 240

var MainStorageOffsetLshVerkleNodeWidth*: UInt256 = one shl twofourty

# ################################################################
#
#        Utility Functions for the Verkle Accounts
#
# ################################################################

# Check if the account loaded is empty or not
proc isEmptyVerkleAccount*(acc: Account): bool =
  var zero: array[32, byte]
  return acc.nonce == 0 and acc.balance.isZero() and acc.codeHash.data == zero

# Spec implementation from the EIP-6800
# Converts a EC Banderwagon point to an
# array of 32 bytes
proc pointToHash*(point: Point, suffix: byte): Bytes32 =
  result = point.hashPointToBytes()
  result[31] = suffix

# To calculate the tree key
# here evaluated address means, when the address
# is evaluated into a EC Banderwagon Point
proc getTreeKeyWithEvaluatedAddress*(evaluated: Point, treeIndex: UInt256, subIndex: byte): Bytes32 =
  var poly: array[256, Field]
  poly[0] = zeroField()
  poly[1] = zeroField()
  poly[2] = zeroField()

  var indexBytes = treeIndex.toBytesLE()
  poly[3].fromLEBytes(indexBytes[0..15])
  poly[4].fromLEBytes(indexBytes[16..^1])

  for i in 5 .. 255:
    poly[i] = zeroField()

  var ret = poly.ipaCommitToPoly()
  ret.banderwagonAddPoint(evaluated)
  return pointToHash(ret, subIndex)

# Convert a ethereum address to a 
# Elliptic Curve (EC) Banderwagon Point
proc evaluateAddressPoint*(address: EthAddress): Point =
  var newAddr: array[32, byte]
  for i in 0 ..< (32 - address.len):
    newAddr[i] = 0
  newAddr[(32 - address.len)..^1] = address

  var poly: array[256, Field]
  
  poly[0] = zeroField()
  poly[1].fromLEBytes(newAddr[0..15])
  poly[2].fromLEBytes(newAddr[16..^1])

  for i in 3 .. 255:
    poly[i] = zeroField()

  var ret = poly.ipaCommitToPoly()

  var getTreePolyIndex0Point: Point
  const a = fromHex(Bytes32, "0x22196df2c10590e04c34bd5cc57e09911b98c782a503d21bc1838e1c6e1a10bf")
  discard getTreePolyIndex0Point.deserialize(a)

  ret.banderwagonAddPoint(getTreePolyIndex0Point)

  return ret

# Get the tree key for a
# particular chunks[i] of the code
proc getTreeKeyCodeChunkIndices*(chunk: UInt256): (UInt256, byte) =
  var chunkOffSet: UInt256
  chunkOffSet = u256(128) + chunk
  var treeIndex: UInt256
  treeIndex = chunkOffSet div u256(256)
  var subIndexMod: UInt256
  subIndexMod = chunkOffSet mod u256(256)
  var subIndex: byte
  if not (subIndexMod == UInt256.zero()):
    subIndex = byte(subIndexMod.limbs[0])
  return (treeIndex, subIndex)

# Get the tree key for a particular storage slot
proc getTreeKeyStorageSlotIndices*(storageKey: openArray[byte]): (UInt256, byte) =
  var treeIndex = UInt256.fromBytesBE(storageKey)

  # If the storage slot exists in the header, then we need to add the header offset
  if treeIndex < CodeStorageDelta:
    treeIndex = treeIndex + HeaderStorageOffset

    # In this branch, the tree-index is 0 since it points to the account header
    # and the sub-index is the LSB of the updated storage Key
    let ret = byte(treeIndex.limbs[0] and byte(0xff))
    return (UInt256.zero(), ret)


  # The first MAIN_STORAGE_OFFSET group will find the 
  # first 64 slots unreachable. 

  let subIndex = storageKey[storageKey.len - 1]

  # Divide the position with VerkleNodeWidthLog2 to avoid an overflow
  treeIndex = treeIndex shr VerkleNodeWidthLog2

  # Add the MAIN_STORAGE_OFFSET lsh VerkleNodeWidth to the position
  treeIndex = treeIndex + MainStorageOffsetLshVerkleNodeWidth

  return (treeIndex, subIndex)

# GetTreeKey performs both the work of the spec's get_tree_key function, and that
# of pedersen_hash: it builds the polynomial in pedersen_hash without having to
# create a mostly zero-filled buffer and "type cast" it to a 128-long 16-byte
# array. Since at most the first 5 coefficients of the polynomial will be non-zero,
# these 5 coefficients are created directly.
proc getTreeKey*(address: EthAddress, treeIndex: UInt256, subIndex: byte): Bytes32 =
  var newAddr {.noinit.} : array[32, byte]
  for i in 0 ..< (32 - address.len):
    newAddr[i] = 0
  newAddr[(32 - address.len)..^1] = address

  # poly = [2+256*64, address_le_low, address_le_high, tree_index_le_low, tree_index_le_high]
  var poly: array[256, Field]

  # 32-byte address, interpreted as two little endian
  # 16-byte numbers.
  poly[1].fromLEBytes(newAddr[0..15])
  poly[2].fromLEBytes(newAddr[16..^1])

  var getTreePolyIndex0Point {.noinit.} : Point
  const a = fromHex(Bytes32, "0x22196df2c10590e04c34bd5cc57e09911b98c782a503d21bc1838e1c6e1a10bf")
  discard getTreePolyIndex0Point.deserialize(a)

  # treeIndex must be interpreted as a 32-byte aligned little-endian integer.
  # e.g: if treeIndex is 0xAABBCC, we need the byte representation to be 0xCCBBAA00...00.
  # poly[3] = LE({CC,BB,AA,00...0}) (16 bytes), poly[4]=LE({00,00,...}) (16 bytes).
  #
  # To avoid unnecessary endianness conversions for nim-eth-verkle, we do some trick:
  # - poly[3]'s byte representation is the same as the *top* 16 bytes (trieIndexBytes[16:]) of
  #   32-byte aligned big-endian representation (BE({00,...,AA,BB,CC})).
  # - poly[4]'s byte representation is the same as the *low* 16 bytes (trieIndexBytes[:16]) of
  #   the 32-byte aligned big-endian representation (BE({00,00,...}).
  var treeIndexBytes = treeIndex.toBytesBE()
  poly[3].fromBEBytes(treeIndexBytes[16..^1])
  poly[4].fromBEBytes(treeIndexBytes[0..15])

  poly[0] = zeroField()
  for i in 5 .. 255:
    poly[i] = zeroField()
  
  var ret = ipaCommitToPoly(poly)

  # add a constant point corresponding to poly[0]=[2+256*64]
  ret.banderwagonAddPoint(getTreePolyIndex0Point)
  return pointToHash(ret, subIndex)

# ################################################################
#
#        Key Generation Operations for the Verkle Trie
#
# ################################################################

proc getTreeKeyHeader*(address: EthAddress): Point =
  var addressPoint : Point = evaluateAddressPoint(address)
  return addressPoint

proc getTreeKeyAccountLeaf*(address: EthAddress, leaf: byte): Bytes32 =
  return getTreeKey(address, UInt256.zero(), leaf)

proc getTreeKeyVersion*(address: EthAddress): Bytes32 =
  return getTreeKey(address, UInt256.zero(), VersionLeafKey)

proc getTreeKeyVersionWithEvaluatedAddress*(addressPoint: Point): Bytes32 =
  return getTreeKeyWithEvaluatedAddress(addressPoint, UInt256.zero(), VersionLeafKey)

proc getTreeKeyBalance*(address: EthAddress): Bytes32 =
  return getTreeKey(address, UInt256.zero(), BalanceLeafKey)

proc getTreeKeyNonce*(address: EthAddress): Bytes32 = 
  return getTreeKey(address, UInt256.zero(), NonceLeafKey)

proc getTreeKeyCodeKeccak*(address: EthAddress): Bytes32 =
  return getTreeKey(address, UInt256.zero(), CodeKeccakLeafKey)

proc getTreeKeyCodeSize*(address: EthAddress): Bytes32 =
  return getTreeKey(address, UInt256.zero(), CodeSizeLeafKey)

proc getTreeKeyCodeChunk*(address: EthAddress, chunk: UInt256): Bytes32 =
  let (treeIndex, subIndex) = getTreeKeyCodeChunkIndices(chunk)
  return getTreeKey(address, treeIndex, subIndex)

proc getTreeKeyCodeChunkWithEvaluatedAddress*(addressPoint: Point, chunk: UInt256): Bytes32 =
  let (treeIndex, subIndex) = getTreeKeyCodeChunkIndices(chunk)
  return getTreeKeyWithEvaluatedAddress(addressPoint, treeIndex, subIndex)

proc getTreeKeyStorageSlotWithEvaluatedAddress*(addressPoint: Point, storageKey: openArray[byte]): Bytes32 =
  let (treeIndex, subIndex) = getTreeKeyStorageSlotIndices(storageKey)
  return getTreeKeyWithEvaluatedAddress(addressPoint, treeIndex, subIndex)

proc newVerkleTrie*(): VerkleTrieRef =
  result = VerkleTrieRef(root: newTree())

# ################################################################
#
#       Verkle Trie Updation Operations from Account
#
# ################################################################

# Updates the storage slots in the Verkle Trie
proc updateStorage*(trie: VerkleTrieRef, address: EthAddress, key, value: var openArray[byte]) =
  var addressPoint: Point
  addressPoint = getTreeKeyHeader(address)
  var k = getTreeKeyStorageSlotWithEvaluatedAddress(addressPoint, key)
  var v: Bytes32
  if value.len >= 32:
    for i in 0..<32:
      v[i] = value[i]
  else:
    let start = 32 - value.len
    for i in 0..<value.len:
      v[start + i] = value[i]
  
  trie.root.setValue(k, v)

# Update the account details in the Verkle Trie
proc updateAccount*(trie: VerkleTrieRef, address: EthAddress, acc: Account) =
  var verKey = getTreeKeyVersion(address)
  var nonceKey = getTreeKeyNonce(address)
  var balanceKey = getTreeKeyBalance(address)
  var codeKeccakKey = getTreeKeyCodeKeccak(address)

  var varVal: Bytes32
  for i in 0 ..< 32:
    if i < varVal.len:
      varVal[i] = 0
  var nonceVal = acc.nonce.toBytesLE()
  var nonceValfull: Bytes32
  for i in 0 ..< 32:
    if i < nonceVal.len:
      nonceValfull[i] = nonceVal[i]
    else:
      nonceValfull[i] = 0

  var balanceVal = acc.balance.toBytesLE()
  trie.root.setValue(verKey, varVal)
  trie.root.setValue(nonceKey, nonceValfull)
  trie.root.setValue(balanceKey, balanceVal)
  trie.root.setValue(codeKeccakKey, acc.codeHash.data)

# Performs hashing ( commitment generation )
# for all the nodes in the Verkle Trie   
proc hashVerkleTrie*(trie: VerkleTrieRef): Bytes32 =
  trie.root.updateAllCommitments()
  return trie.root.commitment.serializePoint()

# ChunkifyCode generates the chunked version of an array representing EVM bytecode
proc chunkifyCode*(code: openArray[byte]) : ChunkedCode =
  var
    chunkOffset = 0 # offset in the chunk
    chunkCount  = len(code) div 31
    codeOffset  = 0 # offset in the code

  if code.len mod 31 != 0:
    chunkCount += 1

  var chunks = newSeq[byte](chunkCount*32)

  for i in 0 ..< chunkCount:
    # number of bytes to copy, 31 unless
    # the end of the code has been reached.
    var endAt = 31 * (i + 1)
    if len(code) < endAt:
      endAt = len(code)

    # Copy the code itself
    for j in 31*i ..< endAt:
      chunks[32*i + 1 + j - 31*i] = code[j]

    # chunk offset = taken from the
    # last chunk.
    if chunkOffset > 31:
      # skip offset calculation if push
      # data covers the whole chunk
      chunks[i*32] = 31
      chunkOffset = 1
      continue

    chunks[32*i] = byte(chunkOffset)
    chunkOffset = 0

    # Check each instruction and update the offset
    # it should be 0 unless a PUSHn overflows.
    while codeOffset < endAt:
      if code[codeOffset] >= byte(Op.Push1) and code[codeOffset] <= byte(Op.Push32):
        codeOffset += int(code[codeOffset] - byte(Op.Push1) + 1)
        if codeOffset+1 >= 31*(i+1):
          codeOffset += 1
          chunkOffset = codeOffset - 31*(i+1)
          break
      codeOffset += 1

  return chunks

# Updates the contract code in the Verkle Trie
# It uses the code chunkification first, and then 
# updates each chunk into the trie, as per EIP-6800
proc updateContractCode*(trie: VerkleTrieRef, address: EthAddress, codeHash: Hash256, code: openArray[byte]) =
  # generate the chunks for the code
  let chunks = chunkifyCode(code)
  var key, value: Bytes32

  var i = 0
  var chunknr = 0
  var groupOffSet = 0

  var values: array[256, ref Bytes32] 
  
  while i < chunks.len:
    # create a internal track when to update at stem level using groupoffset
    groupOffSet = (chunknr + 128) mod 256
    if ((groupOffSet == 0) or (chunknr == 0)):
      key = getTreeKeyCodeChunk(address, u256(chunknr))
      for i in 0 ..< 256:
        values[i] = nil

    # set the chunk value to value
    for j in i ..< i+32:
      value[j-i] = chunks[j]
    
    var heapValue = new Bytes32
    heapValue[] = value
    values[groupOffSet] = heapValue

    if i == 0 :
      var sizeVal = new Bytes32
      let codelength = code.len
      let valueLE = uint64(codelength).toBytesLE()
      var sizeLE: Bytes32
      for i in 0 ..< 32:
        if i < valueLE.len:
          sizeLE[i] = valueLE[i]
        else:
          sizeLE[i] = 0 
      sizeVal[] = sizeLE
      values[CodeSizeLeafKey] = sizeVal

    if ((groupOffSet == 255) or ((chunks.len - i) <= 32)):
      var stem: array[31, byte]
      for j in 0 ..< 31:
        stem[j] = key[j]
      trie.root.setMultipleValues(stem, values)
      trie.root.updateAllCommitments()

    i = i + 32
    chunknr = chunknr + 1

# Helps fetching a account from the verkle trie
# using the account address
proc getAccount*(trie: VerkleTrieRef, address: EthAddress): Account =

  # generate the keys for the account paramas
  var nonceKey = getTreeKeyNonce(address)
  var balanceKey = getTreeKeyBalance(address)
  var codeKeccakKey = getTreeKeyCodeKeccak(address)

  # Fetch the account values from the trie, using the generated keys
  var nonceVal = trie.root.getValue(nonceKey)
  var balanceVal = trie.root.getValue(balanceKey)
  var codeKeccakVal = trie.root.getValue(codeKeccakKey)

  result.nonce = uint64.fromBytesLE(nonceVal[])
  result.balance = UInt256.fromBytesLE(balanceVal[])
  result.codeHash.data = codeKeccakVal[]

# Get returns the value for key stored in the trie. The value bytes must
# not be modified by the caller.
proc getStorage*(trie: VerkleTrieRef, address: EthAddress, key: openArray[byte]): Bytes32 =
  var addressPoint: Point
  addressPoint = getTreeKeyHeader(address)
  var k = getTreeKeyStorageSlotWithEvaluatedAddress(addressPoint, key)
  return trie.root.getValue(k)[]