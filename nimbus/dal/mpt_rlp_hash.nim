#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/strformat,
  ../../vendor/nim-eth/eth/common/eth_hash,
  mpt,
  mpt_nibbles,
  utils

from ../../vendor/nimcrypto/nimcrypto/utils import fromHex

# TODO: Test
# TODO: Optimize

func rlpLegthOfLength(length: int): int =
  if length <= 55: 1
  elif length < 256: 2
  elif length < 65536: 3
  elif length < 16777216: 4
  else: 5


func rlpAppendStringLength(buffer: var seq[byte], length: int) =
  if length <= 55:
    buffer.add 128+length.byte
  elif length < 256:
    buffer.add 184
    buffer.add length.byte
  elif length < 65536:
    buffer.add 185
    buffer.add (length shr 8).byte
    buffer.add length.byte
  elif length < 16777216:
    buffer.add 186
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte
  else:
    buffer.add 187
    buffer.add (length shr 24).byte
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte


func rlpAppendListLength(buffer: var seq[byte], length: int) =
  if length <= 55:
    buffer.add 192+length.byte
  elif length < 256:
    buffer.add 248
    buffer.add length.byte
  elif length < 65536:
    buffer.add 249
    buffer.add (length shr 8).byte
    buffer.add length.byte
  elif length < 16777216:
    buffer.add 250
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte
  else:
    buffer.add 251
    buffer.add (length shr 24).byte
    buffer.add (length shr 16).byte
    buffer.add (length shr 8).byte
    buffer.add length.byte

{.push warning[ProveInit]: off.}

method getOrComputeRlp*(node: MptNode): var seq[byte] {.base.} =
  assert false

{.pop.}


method getOrComputeRlp(leaf: MptLeaf): var seq[byte] =
  if leaf.rlpEncoding.len > 0:
    return leaf.rlpEncoding

  # A leaf is encoded as a RLP list with two items: [path, value]. In case the
  # path's length is even, it's prefixed with 0x20 to discern it from an
  # extension node. In case its length is odd, it's prefixed with 0x3, to
  # complement to a full byte. Both the path and the value are prefixed by their
  # size. A size prefix for strings up to 55 bytes is 1 byte, and the path is
  # always less than 55 bytes.

  let pathLen = 1 + (64 - leaf.logicalDepth.int) div 2
  let blobLen = 1 + pathLen + rlpLegthOfLength(leaf.value.len) + leaf.value.len

  leaf.rlpEncoding.rlpAppendListLength blobLen
  leaf.rlpEncoding.rlpAppendStringLength pathLen

  # Even-length path
  if leaf.logicalDepth mod 2 == 0:
    leaf.rlpEncoding.add 0x20
    leaf.rlpEncoding.add leaf.path.bytes[leaf.logicalDepth div 2 ..< 32]
  else: # odd-length path
    leaf.rlpEncoding.add (0x3 shl 4).byte or leaf.path[leaf.logicalDepth]
    leaf.rlpEncoding.add leaf.path.bytes[leaf.logicalDepth div 2 + 1 ..< 32]

  leaf.rlpEncoding.rlpAppendStringLength leaf.value.len
  leaf.rlpEncoding.add leaf.value
  return leaf.rlpEncoding


method getOrComputeRlp(ext: var MptExtension): var seq[byte] =
  if ext.rlpEncoding.len > 0:
    return ext.rlpEncoding

  # An extension is encoded as a RLP list with two items: [path, child], where
  # child is either the RLP encoding of the child branch node in case it fits
  # in 31 bytes or less, or the 32-bytes hash of that encoding if it doesn't.
  # In case the path's length is even, it's prefixed with 0x00 to discern it
  # from a leaf node. In case its length is odd, it's prefixed with 0x1, to
  # complement to a full byte. Both the path and the child RLP/hash are prefixed
  # by their size. A size prefix for strings up to 55 bytes is 1 byte, and both
  # of them are less than that.

  let pathLen = 1 + ext.remainderPath.len div 2
  let childRlp = addr ext.child.getOrComputeRlp()
  let blobLen = 1 + pathLen + 1 + min(childRlp.len, 32)

  leaf.rlpEncoding.rlpAppendListLength blobLen
  leaf.rlpEncoding.rlpAppendStringLength pathLen

  # Even-length path
  if ext.remainderPath.len mod 2 == 0:
    leaf.rlpEncoding.add 0x00
    leaf.rlpEncoding.add ext.remainderPath.bytes[0 ..< ext.remainderPath.len div 2]
  else: # odd-length path
    leaf.rlpEncoding.add (0x1 shl 4).byte or leaf.path[leaf.logicalDepth]
    leaf.rlpEncoding.add leaf.path.bytes[leaf.logicalDepth div 2 + 1 ..< 32]


  var pathEncodedLen = rlpLegthOfLength(ext.remainderPath.len)
  if ext.remainderPath.len mod 2 == 0:
    inc pathEncodedLen # for the 0x00 marker

  var encodedLen = 1 + pathEncodedLen + rlpLegthOfLength(ext.value.len) + ext.value.len



var emptyRlpHash: ref array[32, byte]
new emptyRlpHash
emptyRlpHash[0..<32] = "56E81F171BCC55A6FF8345E692C0F86E5B48E01B996CADC001622FB5E363B421".fromHex[0..<32]


proc getOrComputeHash*(diff: var DiffLayer): ref array[32, byte] =
  if diff.hash != nil:
    return diff.hash

  if diff.root == nil:
    return emptyRlpHash

  new diff.hash
  diff.hash[] = keccakHash(diff.root.getOrComputeRlp).data
  return diff.hash
