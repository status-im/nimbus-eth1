#   Nimbus
#   Copyright (c) 2021-2024 Status Research & Development GmbH
#   Licensed and distributed under either of
#     * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#     * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
#   at your option. This file may not be copied, modified, or distributed except according to those terms.

##  This module handles computing the Merkle hash of MPT nodes. The Merkle hash
##  of a node is computed by serializing it into RLP (Recursive Length Prefix)
##  form, 

# TODO: Test
# TODO: Optimize

# consider using an array to serialize data instead of seq. problem is accounts could be large.

import
  ../../vendor/nim-eth/eth/common/eth_hash,
  mpt,
  mpt_nibbles,
  config

from ../../vendor/nimcrypto/nimcrypto/utils import fromHex
when TraceLogs: import utils


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



method toRlp*(node: MptNode, buffer: var seq[byte]) {.base.} =
  ## Serialize the node using RLP into the provided buffer. If the node has
  ## children nodes and doesn't have their hash, it will call `toRlp`
  ## recursively, and cache their hashes. `MptBranch` nodes must either have the
  ## hash of their children, or the children loaded to compute their RLP.
  ## Note: the buffer might be cleared of its previous contents.
  assert false



method toRlp(leaf: MptLeaf, buffer: var seq[byte]) =
  # A leaf is encoded as a RLP list with two items: [path, value]. In case the
  # path's length is even, it's prefixed with 0x20 to discern it from an
  # extension node. In case its length is odd, it's prefixed with 0x3, to
  # complement to a full byte. Both the path and the value are prefixed by their
  # size. A size prefix for strings up to 55 bytes is 1 byte, and the path is
  # always less than 55 bytes.

  let pathLen = 1 + (64 - leaf.logicalDepth.int) div 2
  let blobLen = 1 + pathLen + rlpLegthOfLength(leaf.value.len) + leaf.value.len

  buffer.setLen 0
  buffer.rlpAppendListLength blobLen
  buffer.rlpAppendStringLength pathLen

  if leaf.logicalDepth mod 2 == 0: # Even-length path
    buffer.add 0x20
    buffer.add leaf.path.bytes[leaf.logicalDepth div 2 ..< 32]
  else: # odd-length path
    buffer.add (0x3 shl 4).byte or leaf.path[leaf.logicalDepth]
    buffer.add leaf.path.bytes[leaf.logicalDepth div 2 + 1 ..< 32]

  buffer.rlpAppendStringLength leaf.value.len
  buffer.add leaf.value
  when TraceLogs: echo "Leaf: " & buffer.toHex



method toRlp(ext: MptExtension, buffer: var seq[byte]) =
  # If we don't have the child's hash/RLP, compute it first
  if ext.childHashOrRlp.len == 0:
    ext.child.toRlp(buffer)
    if buffer.len < 32:
      ext.childHashOrRlp = buffer
    else: ext.childHashOrRlp.add keccakHash(buffer).data

  # An extension is encoded as a RLP list with two items: [path, child], where
  # child is either the RLP encoding of the child branch node in case it fits
  # in 31 bytes or less, or the 32-bytes hash of that encoding if it doesn't.
  # In case the path's length is even, it's prefixed with 0x00 to discern it
  # from a leaf node. In case its length is odd, it's prefixed with 0x1, to
  # complement to a full byte. Both the path and the child RLP/hash are prefixed
  # by their size. A size prefix for strings up to 55 bytes is 1 byte, and both
  # of them are less than that.

  let pathLen = 1 + ext.remainderPath.len div 2
  var blobLen = 1 + pathLen + ext.childHashOrRlp.len
  if ext.childHashOrRlp.len == 32: # It's a hash; need a length prefix
    inc blobLen

  buffer.setLen 0
  buffer.rlpAppendListLength blobLen
  buffer.rlpAppendStringLength pathLen

  if ext.remainderPath.len mod 2 == 0: # Even-length path
    buffer.add 0x00
    buffer.add ext.remainderPath.bytes[0 ..< ext.remainderPath.len div 2]
  else: # odd-length path
    buffer.add (0x1 shl 4).byte or ext.remainderPath.bytes[0]
    buffer.add ext.remainderPath.bytes[1 .. ext.remainderPath.len div 2]

  if ext.childHashOrRlp.len == 32:
    buffer.add 0xa0 # RLP code for 32-bytes string
  buffer.add ext.childHashOrRlp # No need for length prefix; included in RLP blob
  when TraceLogs: echo "Extension: " & buffer.toHex



method toRlp(branch: MptBranch, buffer: var seq[byte]) =
  var blobLen = 1 # Starting from 1 due to 17th item

  # If we don't have a child's hash/RLP, compute it first
  # Also, compute the size of the resulting RLP (blobLen)
  for offset in 0.uint8 ..< 16:
    if branch.childExists offset:
      if branch.childHashesOrRlps[offset].len == 0:
        branch.children[offset].toRlp(buffer)
        if buffer.len < 32:
          branch.childHashesOrRlps[offset] = buffer
        else: branch.childHashesOrRlps[offset].add keccakHash(buffer).data
      if branch.childHashesOrRlps[offset].len == 32:
        inc blobLen # Hash; add length prefix
      blobLen += branch.childHashesOrRlps[offset].len # RLP; no need for length prefix
    else: inc blobLen

  # A branch is encoded as a RLP list with 17 items. Each item on the list is a
  # child node's own RLP in case it fits in 31 bytes or less, or the 32-bytes
  # hash of that encoding if it doesn't. The 17th item is unused and left empty.
  buffer.setLen 0
  buffer.rlpAppendListLength blobLen
  for offset in 0.uint8 ..< 16:
    if branch.childExists offset:
      if branch.childHashesOrRlps[offset].len == 32:
        buffer.add 0xa0 # RLP code for 32-bytes string
      buffer.add branch.childHashesOrRlps[offset] # No need for length prefix; included in RLP blob
    else: buffer.add 0x80 # empty string
  buffer.add 0x80 # empty string
  when TraceLogs: echo "Branch: " & buffer.toHex



var emptyRlpHash: ref array[32, byte]
new emptyRlpHash
emptyRlpHash[0..<32] = "56E81F171BCC55A6FF8345E692C0F86E5B48E01B996CADC001622FB5E363B421".fromHex[0..<32]


proc getOrComputeHash*(diff: var DiffLayer): ref array[32, byte] =
  if diff.hash != nil:
    return diff.hash

  if diff.root == nil:
    return emptyRlpHash

  new diff.hash
  var buffer = newSeqOfCap[byte](1024)
  diff.root.toRlp(buffer)
  diff.hash[] = keccakHash(buffer).data
  return diff.hash
