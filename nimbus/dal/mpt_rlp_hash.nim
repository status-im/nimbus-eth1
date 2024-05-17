#[  Nimbus
    Copyright (c) 2021-2024 Status Research & Development GmbH
    Licensed and distributed under either of
      * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
      * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
    at your option. This file may not be copied, modified, or distributed except according to those terms. ]#


##[ This module handles computing the Merkle hash of MPT nodes. A hash is computed recursively
    bottom-up. Nodes are serialized into RLP form (Recursive Length Prefix), and the RLP is then
    hashed using keccak in case its length is 32 bytes or more. We use hand-crafted RLP encoding for
    better performance, and avoid memory allocations. ]##


import
  ../../../vendor/nimcrypto/nimcrypto/keccak,
  ./[mpt, mpt_nibbles, config]


type
  # A buffer used for RLP encoding. We can never exceed this size.
  Buffer = object
    bytes: array[1024, byte]
    len: int


func add(buffer: var Buffer, b: byte) {.inline.} =
  buffer.bytes[buffer.len] = b
  inc buffer.len


when TraceLogs:
  import std/strformat, ./utils
  func `$`(buffer: var Buffer): string =
    buffer.bytes[0..<buffer.len].toHex


func rlpAppendStringLength(buffer: var Buffer, length: int) {.inline.} =
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


func rlpAppendListLength(buffer: var Buffer, length: int) {.inline.} =
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



method computeHashOrRlpIfNeeded*(node: MptNode, logicalDepth: uint8) {.base.} =
  #[ Serialize the node using RLP and keccak-hash the RLP if it's 32 bytes or more. Store the result
     in `node.hashOrRlp`. Does nothing if `node.hashOrRlp.len > 0`. Calls `computeHashOrRlpIfNeeded`
     on child nodes recursively. ]#
  doAssert false


method computeHashOrRlpIfNeeded*(notLoaded: MptNotLoaded, logicalDepth: uint8) =
  # We always have the hash of a node that wasn't yet loaded, so there's no need to compute it.
  doAssert notLoaded.hashOrRlp.len > 0


method computeHashOrRlpIfNeeded(leaf: MptLeaf, logicalDepth: uint8) =
  if leaf.hashOrRlp.len > 0:
    return
  
  #[ A leaf is encoded as a RLP list with two items: [path, value]. In case the path's length is
     even, it's prefixed with 0x20 to discern it from an extension node. In case its length is odd,
     it's prefixed with 0x3, to complement to a full byte.

     PERF TODO: if we know the leaf is going to encode into 31 bytes or less, we could serialize it
     straight into node's buffer instead of into the temaporary buffer and then copying it. ]#

  let pathPrefixLen =
    if logicalDepth >= 63: 0
    else: 1
  let pathLen = 1 + (64 - logicalDepth.int) div 2
  let leafPrefixLen =
    if leaf.value.len == 1 and leaf.value.bytes[0] < 128: 0
    else: 1
  let blobLen = pathPrefixLen + pathLen + leafPrefixLen + leaf.value.len.int

  var buffer {.noinit.}: Buffer
  buffer.len = 0
  buffer.rlpAppendListLength blobLen
  if pathPrefixLen > 0:
    buffer.rlpAppendStringLength pathLen

  # TODO PERF: copy memory in bulk
  # Serialize path
  if logicalDepth mod 2 == 0: # Even-length path
    buffer.add 0x20
    for i in logicalDepth div 2 ..< 32:
      buffer.add leaf.path.bytes[i]
  else: # odd-length path
    buffer.add (0x3 shl 4).byte or leaf.path[logicalDepth].byte
    for i in logicalDepth div 2 + 1 ..< 32:
      buffer.add leaf.path.bytes[i]

  # Serialize value. In case the value is a single ASCII byte, we don't need a length prefix
  if leaf.value.len == 1 and leaf.value.bytes[0] < 128:
    buffer.add leaf.value.bytes[0]
  else:
    buffer.rlpAppendStringLength leaf.value.len.int
    for i in 0 ..< leaf.value.len.int:
      buffer.add leaf.value.bytes[i]

  when TraceLogs: echo &"Leaf {$leaf.path} at depth {logicalDepth:2} RLP: {$buffer}"

  # Encoded RLP is less than 32 bytes long? Store it as-is
  if buffer.len < 32:
    leaf.hashOrRlp.bytes[0..<buffer.len] = buffer.bytes[0..<buffer.len]
    leaf.hashOrRlp.len = buffer.len.uint8

  # Encoded RLP is 32 bytes long or more? Keccak-hash it and store the 32-bytes hash
  else:
    leaf.hashOrRlp.bytes[0..<32] = keccak256.digest(addr buffer.bytes[0], buffer.len.uint).data
    leaf.hashOrRlp.len = 32



method computeHashOrRlpIfNeeded(ext: MptExtension, logicalDepth: uint8) =
  if ext.hashOrRlp.len > 0:
    return

  # An extension is encoded as a RLP list with two items: [path, child], where
  # child is either the RLP encoding of the child branch node in case it fits
  # in 31 bytes or less, or the 32-bytes hash of that encoding if it doesn't.
  # In case the path's length is even, it's prefixed with 0x00 to discern it
  # from a leaf node. In case its length is odd, it's prefixed with 0x1, to
  # complement to a full byte. Both the path and the child RLP/hash are prefixed
  # by their size. A size prefix for strings up to 55 bytes is 1 byte, and both
  # of them are less than that.

  ext.child.computeHashOrRlpIfNeeded logicalDepth + ext.remainderPath.len.uint8
  let pathPrefixLen =
    if ext.remainderPath.len == 1: 0'u8
    else: 1
  let pathLen = 1 + ext.remainderPath.len div 2
  var blobLen = pathPrefixLen + pathLen + ext.child.hashOrRlp.len
  if ext.child.hashOrRlp.len == 32: # It's a hash; need a length prefix
    inc blobLen

  var buffer {.noinit.}: Buffer
  buffer.len = 0
  buffer.rlpAppendListLength blobLen.int
  if pathPrefixLen > 0:
    buffer.rlpAppendStringLength pathLen.int

  # TODO PERF: copy memory in bulk
  if ext.remainderPath.len mod 2 == 0: # Even-length path
    buffer.add 0x00
    for i in 0 ..< ext.remainderPath.len.int div 2:
      buffer.add (ext.remainderPath[i*2] shl 4 or ext.remainderPath[i*2+1]).byte
  else: # odd-length path
    buffer.add (0x1 shl 4).byte or ext.remainderPath[0].byte
    for i in 0 ..< ext.remainderPath.len.int div 2:
      buffer.add (ext.remainderPath[i*2+1] shl 4 or ext.remainderPath[(i+1)*2]).byte

  if ext.child.hashOrRlp.len == 32:
    buffer.add 0xa0 # RLP code for 32-bytes string
  for i in 0 ..< ext.child.hashOrRlp.len.int: # No need for length prefix; included in RLP blob
    buffer.add ext.child.hashOrRlp.bytes[i]

  when TraceLogs: echo &"Extend {$ext.remainderPath:62} at depth {logicalDepth:2} RLP: {$buffer}"

  if buffer.len < 32:
    ext.hashOrRlp.bytes[0..<buffer.len] = buffer.bytes[0..<buffer.len]
    ext.hashOrRlp.len = buffer.len.uint8
  else:
    ext.hashOrRlp.bytes[0..<32] = keccak256.digest(addr buffer.bytes[0], buffer.len.uint).data
    ext.hashOrRlp.len = 32



method computeHashOrRlpIfNeeded(branch: MptBranch, logicalDepth: uint8) =
  if branch.hashOrRlp.len > 0:
    return

  var blobLen = 1 # Starting from 1 due to 17th item

  # If we don't have a child's hash/RLP, compute it first
  # Also, compute the size of the resulting RLP (blobLen)
  for offset in 0.uint8 ..< 16:
    if branch.children[offset] != nil:
      branch.children[offset].computeHashOrRlpIfNeeded logicalDepth+1
      let childHashLen = branch.children[offset].hashOrRlp.len.int
      if childHashLen == 32:
        blobLen += childHashLen + 1  # Hash; add length prefix
      else: blobLen += childHashLen  # RLP; no need for length prefix
    else: inc blobLen

  # A branch is encoded as a RLP list with 17 items. Each item on the list is a
  # child node's own RLP in case it fits in 31 bytes or less, or the 32-bytes
  # hash of that encoding if it doesn't. The 17th item is unused and left empty.
  var buffer {.noinit.}: Buffer
  buffer.len = 0
  buffer.rlpAppendListLength blobLen
  for offset in 0.uint8 ..< 16:
    if branch.children[offset] != nil:
      let childHashLen = branch.children[offset].hashOrRlp.len.int
      if childHashLen == 32:
        buffer.add 0xa0 # RLP code for 32-bytes string
      for i in 0 ..< childHashLen: # No need for length prefix; included in RLP blob
        buffer.add branch.children[offset].hashOrRlp.bytes[i]
    else: buffer.add 0x80 # empty string
  buffer.add 0x80 # empty string

  when TraceLogs: echo &"Branch                                                                at depth {logicalDepth:2} RLP: {$buffer}"

  if buffer.len < 32:
    branch.hashOrRlp.bytes[0..<buffer.len] = buffer.bytes[0..<buffer.len]
    branch.hashOrRlp.len = buffer.len.uint8
  else:
    branch.hashOrRlp.bytes[0..<32] = keccak256.digest(addr buffer.bytes[0], buffer.len.uint).data
    branch.hashOrRlp.len = 32


const emptyRlpHash*: array[32, byte] =
  [0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6, 0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
   0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0, 0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21]


func rootHash*(diff: DiffLayer): array[32, byte] =
  ## Returns the Keccak-256 Merkle hash of the tree
  if diff.root == nil:
    return emptyRlpHash
  else:
    diff.root.computeHashOrRlpIfNeeded 0
    if diff.root.hashOrRlp.len == 32:
      return diff.root.hashOrRlp.bytes
    else: return keccak256.digest(addr diff.root.hashOrRlp.bytes[0], diff.root.hashOrRlp.len.uint).data
