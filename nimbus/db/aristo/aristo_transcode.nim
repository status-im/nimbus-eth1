# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/sequtils,
  eth/[common, trie/nibbles],
  stew/results,
  ../../sync/snap/range_desc,
  "."/[aristo_desc, aristo_error]

# Example of a compacted Merkle Patrica Trie encoded for a key-value table
# from http://archive.is/TinyK
#
#   lookup data:
#     "do":    "verb"
#     "dog":   "puppy"
#     "dodge": "coin"
#     "horse": "stallion"
#
#   trie DB:
#     root: [16 A]
#     A:    [* * * * B * * * [20+"orse" "stallion"] * * * * * * *  *]
#     B:    [00+"o" D]
#     D:    [* * * * * * E * * * * * * * * *  "verb"]
#     E:    [17 [* * * * * * [35 "coin"] * * * * * * * * * "puppy"]]
#
#     with first nibble of two-column rows:
#       hex bits | node type  length
#       ---------+------------------
#        0  0000 | extension   even
#        1  0001 | extension   odd
#        2  0010 | leaf        even
#        3  0011 | leaf        odd
#
#    and key path:
#        "do":     6 4 6 f
#        "dog":    6 4 6 f 6 7
#        "dodge":  6 4 6 f 6 7 6 5
#        "horse":  6 8 6 f 7 2 7 3 6 5

const
  EmptyBlob = seq[byte].default
    ## Useful shortcut (borrowed from `sync/snap/constants.nim`)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc aristoError(error: AristoError): NodeRef =
  NodeRef(kind: Dummy, reason: error)

# ------------------------------------------------------------------------------
# Public RLP transcoder mixins
# ------------------------------------------------------------------------------

proc read*(rlp: var Rlp; T: type NodeRef): T {.gcsafe, raises: [RlpError]} =
  ## Mixin for RLP writer, see `fromRlpRecord()` for an encoder with detailed
  ## error return code (if needed.) This reader is a jazzed up version which
  ## reports some particular errors in the `Dummy` type node.
  if not rlp.isList:
    # Otherwise `rlp.items` would raise a `Defect`
    return aristoError(Rlp2Or17ListEntries)

  var
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,NodeKey]        # reconstruct branch node
    top = 0                         # count entries and positions

  # Collect lists of either 2 or 17 blob entries.
  for w in rlp.items:
    case top
    of 0, 1:
      if not w.isBlob:
        return aristoError(RlpBlobExpected)
      blobs[top] = rlp.read(Blob)
    of 2 .. 15:
      if not links[top].init(rlp.read(Blob)):
        return aristoError(RlpBranchLinkExpected)
    of 16:
      if not w.isBlob:
        return aristoError(RlpBlobExpected)
      if 0 < rlp.read(Blob).len:
        return aristoError(RlpEmptyBlobExpected)
    else:
      return aristoError(Rlp2Or17ListEntries)
    top.inc

  # Verify extension data
  case top
  of 2:
    if blobs[0].len == 0:
      return aristoError(RlpNonEmptyBlobExpected)
    let (isLeaf, pathSegment) = hexPrefixDecode blobs[0]
    if isLeaf:
      return NodeRef(
        kind:   Leaf,
        lPfx:   pathSegment,
        lData:  PayloadRef(
          kind: BlobData,
          blob: blobs[1]))
    else:
      var key: NodeKey
      if not key.init(blobs[1]):
        return aristoError(RlpExtPathEncoding)
      return NodeRef(
        kind: Extension,
        ePfx: pathSegment,
        eKey: key)
  of 17:
    for n in [0,1]:
      if not links[n].init(blobs[n]):
        return aristoError(RlpBranchLinkExpected)
    return NodeRef(
      kind: Branch,
      bKey: links)
  else:
    discard

  aristoError(Rlp2Or17ListEntries)


proc append*(writer: var RlpWriter; node: NodeRef) =
  ## Mixin for RLP writer. Note that a `Dummy` node is encoded as an empty
  ## list.
  proc addNodeKey(writer: var RlpWriter; key: NodeKey) =
    if key.isZero:
      writer.append EmptyBlob
    else:
      writer.append key.to(Hash256)

  case node.kind:
  of Branch:
    writer.startList(17)
    for n in 0 ..< 16:
      writer.addNodeKey node.bKey[n]
    writer.append(EmptyBlob)
  of Extension:
    writer.startList(2)
    writer.append node.ePfx.hexPrefixEncode(isleaf = false)
    writer.addNodeKey node.eKey
  of Leaf:
    writer.startList(2)
    writer.append node.lPfx.hexPrefixEncode(isleaf = true)
    writer.append node.lData.convertTo(Blob)
    #case node.lData.kind:
    #of BlobData:
    #  writer.append node.lData.blob
    #of AccountData:
    #  writer.append node.lData.account.encode
  of Dummy:
    writer.startList(0)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fromRlpRecord*(data: Blob): NodeRef =
  ## Convert an RLP encoded hexary node to a `NodeRef`.
  if data.len == 0:
    return aristoError(RlpNonEmptyBlobExpected)
  try:
    var w = data.rlpFromBytes
    return w.read(NodeRef)
  except RlpError:
    return aristoError(RlpRlpException)
  except CatchableError:
    discard
  aristoError(RlpOtherException)

proc toRlpRecord*(node: NodeRef): Blob =
  ## Encode a node as an RLP encoded byte stream. This function is a shorcut
  ## for `node.encode()`
  node.encode()

# ------------------------------------------------------------------------------
# Public db record transcoders
# ------------------------------------------------------------------------------

proc toDbRecord*(node: NodeRef): Blob =
  ## This function serialises the node argument to a database record. Contrary
  ## to RLP based serialisation, these records aim to align on fixed byte
  ## boundaries.
  ## ::
  ##   Branch:
  ##     offset(4)      -- offset of NodeKey list (and zero leading bit)
  ##     access(16)     -- index offsets byte array
  ##     uint64, ...    -- list of up to 16 child nodes lookup keys
  ##     NodeKey, ...   -- list of up to 16 hash keys of child nodes
  ##
  ##   Extension:
  ##     offset(4)      -- extension marker: 2 * 2^30 + 44 (offset of path Blob)
  ##     uint64         -- child node lookup key
  ##     NodeKey        -- hash key of child node
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##
  ##   Leaf:
  ##     offset(4)      -- leaf marker: 3 * 2^30 + 8 + <leaf-data-length>
  ##     Blob           -- opaque leaf data payload (might be zero length)
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##
  ## For a branch record, the bytes of the `access(16)` array indicate the
  ## position of the Patricia Trie node reference and the hash keys. So the
  ## particular byte with index `n` has
  ## ::
  ##   W = value (ranging 0..16) of byte with index n
  ##   if 0 < W:
  ##     lookup key = 12 + W * 8
  ##     child hash = offset(4) - 32 + W * 32
  ##   else:
  ##     no such entry
  ##
  ## For a branch record the `offset(4)` is 36 at minimum as there are at
  ## least two children by design. So the minimum size of a branch node is
  ## 100 bytes and the maximum size is 640 bytes, 512 bytes of which is
  ## occupied by the list of hashes.
  ##
  ## For a leaf record, the maximal data payload size is 2^30-5 due to the
  ## fact that the first two bits of the offset value are used as marker.
  ##
  case node.kind:
  of Branch:
    var
      top = 0.byte
      access = newSeq[byte](16)
      refs: Blob
      keys: Blob
    for n in 0 .. 15:
      if not node.bVtx[n].isZero:
        top.inc
        access[n] = top
        refs &= node.bVtx[n].uint64.toBytesBE.toSeq
        keys &= node.bKey[n].ByteArray32.toSeq
    result = (20 + refs.len).uint32.toBytesBE.toSeq & access & refs & keys
  of Extension:
    const extPrefix = @[128u8, 0u8, 0u8, 44u8] # 0x80'00'00'2C
    result = extPrefix &
      node.eVtx.uint64.toBytesBE.toSeq &
      node.eKey.ByteArray32.toSeq &
      node.ePfx.hexPrefixEncode(isleaf = false)
  of Leaf:
    let data = node.lData.convertTo(Blob)
    result = (0xC0000004 + data.len).uint32.toBytesBE.toSeq &
      data &
      node.lPfx.hexPrefixEncode(isleaf = true)
  of Dummy:
    discard

proc fromDbRecord*(record: Blob): NodeRef =
  ## De-serialise a data record encoded with `toDbRecord()`.
  if record.len < 5:
    return aristoError(DbrTooShort)
  let
    offset = (uint32.fromBytesBE(record[0..3]) and 0x3fffffff).int
  if record.len <= offset:
    return aristoError(DbrOffsOutOfRange)

  case record[0] shr 6:
  of 0: # `Branch` node
    if record.len < 100:
      return aristoError(DbrBranchTooShort)
    if offset < 36:
      return aristoError(DbrBranchOffsTooSmall)
    var
      node = NodeRef(kind: Branch)
    let
      maxInx = (record.len - offset) div 32
      off32 = offset - 32
    for n in 0 .. 15:
      let inx = record[4 + n].int
      if 0 < inx:
        if maxInx < inx:
          # There is no much advantage doing this for the largest value
          # of `inx` only as this check is inexpensive.
          return aristoError(DbrBranchInxOutOfRange)
        block:
          let w = 12 + (inx shl 3)      # times 8
          node.bVtx[n] = (uint64.fromBytesBE record[w ..< w + 8]).VertexID
        block:
          let w = off32 + (inx shl 5)   # times 32
          (addr node.bKey[n].ByteArray32[0]).copyMem(unsafeAddr record[w], 32)
      # End `for`
    return node

  of 2: # `Extension` node
    if record.len < 45:
      return aristoError(DbrExtTooShort)
    if offset != 44:
      return aristoError(DbrExtGarbled)
    let (isLeaf, pathSegment) = hexPrefixDecode record[44 ..< record.len]
    if isLeaf:
      return aristoError(DbrExtGotLeafPrefix)
    var node = NodeRef(
      kind: Extension,
      eVtx: (uint64.fromBytesBE record[4 ..< 12]).VertexID,
      ePfx: pathSegment)
    (addr node.eKey.ByteArray32[0]).copyMem(unsafeAddr record[12], 32)
    return node

  of 3: # `Leaf` node
    let (isLeaf, pathSegment) = hexPrefixDecode record[offset ..< record.len]
    if not isLeaf:
      return aristoError(DbrLeafGotExtPrefix)
    return NodeRef(
      kind:   Leaf,
      lPfx:   pathSegment,
      lData:  PayloadRef(
        kind: BlobData,
        blob: record[4 ..< offset]))
  else:
    discard

  aristoError(DbrUnknown)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
