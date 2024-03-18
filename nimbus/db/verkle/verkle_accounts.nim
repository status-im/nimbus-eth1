# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/algorithm,
  eth/common,
  stew/[byteutils, endians2], stint,
  "../../../vendor/nim-eth-verkle/eth_verkle"/[
    math, 
    utils, 
    tree/tree, 
    tree/operations, 
    tree/commitment
  ],
  "../../../vendor/nim-eth-verkle/constantine/constantine"/[
    serialization/codecs, 
    serialization/codecs_banderwagon
  ]

type
  VerkleTrie = ref object
    root: BranchesNode
  # db: <something>
  # persistcheck: <some-flag>

const
  VersionLeafKey = 0
  BalanceLeafKey = 1
  NonceLeafKey = 2
  CodeKeccakLeafKey = 3
  CodeSizeLeafKey = 4


proc pointToHash*(point: Point, suffix: byte): Bytes32 =
  result = point.serializePoint()
  result.reverse()
  result[31] = suffix

proc getTreeKeyWithEvaluatedAddress*(evaluated: Point, treeIndex: UInt256, subIndex: byte): Bytes32 =
  var poly: array[5, Field]
  poly[0] = zeroField()
  poly[1] = zeroField()
  poly[2] = zeroField()

  var indexBytes = treeIndex.toBytesLE()
  poly[3].fromLEBytes(indexBytes[0..15])
  poly[4].fromLEBytes(indexBytes[16..^1])

  var ret = poly.ipaCommitToPoly()
  ret.banderwagonAddPoint(evaluated)
  return pointToHash(ret, subIndex)

proc evaluateAddressPoint*(address: EthAddress): Point =
  var newAddr: array[32, byte]
  for i in 0 ..< (32 - address.len):
    newAddr[i] = 0
  newAddr[(32 - address.len)..^1] = address

  var poly: array[3, Field]
  
  poly[0] = zeroField()
  poly[1].fromLEBytes(newAddr[0..15])
  poly[2].fromLEBytes(newAddr[16..^1])

  var ret = poly.ipaCommitToPoly()

  var getTreePolyIndex0Point: Point
  var a = fromHex(Bytes32, "0x22196df2c10590e04c34bd5cc57e09911b98c782a503d21bc1838e1c6e1a10bf")
  discard getTreePolyIndex0Point.deserialize(a)

  ret.banderwagonAddPoint(getTreePolyIndex0Point)

  return ret

proc getTreeKey*(address: EthAddress, treeIndex: UInt256, subIndex: byte): Bytes32 =
  var newAddr: array[32, byte]
  for i in 0 ..< (32 - address.len):
    newAddr[i] = 0
  newAddr[(32 - address.len)..^1] = address

  var poly: array[5, Field]
  var b: array[4, byte]
  b[0] = 0
  b[1] = 0
  b[2] = 2
  b[3] = 40
  poly[0].fromLEBytes(b) # 2+256*64
  poly[1].fromLEBytes(newAddr[0..15])
  poly[2].fromLEBytes(newAddr[16..^1])

  var treeIndexBytes = treeIndex.toBytesBE()
  poly[3].fromLEBytes(treeIndexBytes[0..15])
  poly[4].fromLEBytes(treeIndexBytes[16..^1])

  var ret = poly.ipaCommitToPoly()
  return pointToHash(ret, subIndex)

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


proc updateAccount*(trie: var VerkleTrie, address: EthAddress, acc: Account) =
  var verKey = getTreeKeyVersion(address)
  var nonceKey = getTreeKeyNonce(address)
  var balanceKey = getTreeKeyBalance(address)
  var codeKeccakKey = getTreeKeyCodeKeccak(address)

  var varVal = fromHex(Bytes32, "0x0")
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

    
proc hashVerkleTrie*(trie: var VerkleTrie): Bytes32 =
  trie.root.updateAllCommitments()
  return trie.root.commitment.serializePoint()