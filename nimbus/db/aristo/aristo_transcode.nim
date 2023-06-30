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
  std/[bitops, sequtils],
  eth/[common, trie/nibbles],
  stew/results,
  "."/[aristo_constants, aristo_desc]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc aristoError(error: AristoError): NodeRef =
  ## Allows returning de
  NodeRef(vType: Leaf, error: error)

# ------------------------------------------------------------------------------
# Public RLP transcoder mixins
# ------------------------------------------------------------------------------

proc read*(
    rlp: var Rlp;
    T: type NodeRef;
      ): T {.gcsafe, raises: [RlpError]} =
  ## Mixin for RLP writer, see `fromRlpRecord()` for an encoder with detailed
  ## error return code (if needed.) This reader is a jazzed up version which
  ## reports some particular errors in the `Dummy` type node.
  if not rlp.isList:
    # Otherwise `rlp.items` would raise a `Defect`
    return aristoError(Rlp2Or17ListEntries)

  var
    blobs = newSeq[Blob](2)         # temporary, cache
    links: array[16,HashKey]        # reconstruct branch node
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
        vType:   Leaf,
        lPfx:    pathSegment,
        lData:   PayloadRef(
          pType: BlobData,
          blob:  blobs[1]))
    else:
      var node = NodeRef(
        vType: Extension,
        ePfx:  pathSegment)
      if not node.key[0].init(blobs[1]):
        return aristoError(RlpExtPathEncoding)
      return node
  of 17:
    for n in [0,1]:
      if not links[n].init(blobs[n]):
        return aristoError(RlpBranchLinkExpected)
    return NodeRef(
      vType: Branch,
      key:   links)
  else:
    discard

  aristoError(Rlp2Or17ListEntries)


proc append*(writer: var RlpWriter; node: NodeRef) =
  ## Mixin for RLP writer. Note that a `Dummy` node is encoded as an empty
  ## list.
  proc addHashKey(writer: var RlpWriter; key: HashKey) =
    if not key.isValid:
      writer.append EmptyBlob
    else:
      writer.append key.to(Hash256)

  if node.error != AristoError(0):
    writer.startList(0)
  else:
    case node.vType:
    of Branch:
      writer.startList(17)
      for n in 0..15:
        writer.addHashKey node.key[n]
      writer.append EmptyBlob
    of Extension:
      writer.startList(2)
      writer.append node.ePfx.hexPrefixEncode(isleaf = false)
      writer.addHashKey node.key[0]
    of Leaf:
      writer.startList(2)
      writer.append node.lPfx.hexPrefixEncode(isleaf = true)
      writer.append node.lData.convertTo(Blob)

# ------------------------------------------------------------------------------
# Public db record transcoders
# ------------------------------------------------------------------------------

proc blobify*(vtx: VertexRef; data: var Blob): AristoError =
  ## This function serialises the vertex argument to a database record.
  ## Contrary to RLP based serialisation, these records aim to align on
  ## fixed byte boundaries.
  ## ::
  ##   Branch:
  ##     uint64, ...    -- list of up to 16 child vertices lookup keys
  ##     uint16         -- index bitmap
  ##     0x00           -- marker(2) + unused(2)
  ##
  ##   Extension:
  ##     uint64         -- child vertex lookup key
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##     0x80           -- marker(2) + unused(2)
  ##
  ##   Leaf:
  ##     Blob           -- opaque leaf data payload (might be zero length)
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##     0xc0           -- marker(2) + partialPathLen(6)
  ##
  ## For a branch record, the bytes of the `access` array indicate the position
  ## of the Patricia Trie vertex reference. So the `vertexID` with index `n` has
  ## ::
  ##   8 * n * ((access shr (n * 4)) and 15)
  ##
  case vtx.vType:
  of Branch:
    var
      top = 0u64
      access = 0u16
      refs: Blob
      keys: Blob
    for n in 0..15:
      if vtx.bVid[n].isValid:
        access = access or (1u16 shl n)
        refs &= vtx.bVid[n].uint64.toBytesBE.toSeq
    if refs.len < 16:
      return BlobifyBranchMissingRefs
    data = refs & access.toBytesBE.toSeq & @[0u8]
  of Extension:
    let
      pSegm = vtx.ePfx.hexPrefixEncode(isleaf = false)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < pslen:
      return BlobifyExtPathOverflow
    if not vtx.eVid.isValid:
      return BlobifyExtMissingRefs
    data = vtx.eVid.uint64.toBytesBE.toSeq & pSegm & @[0x80u8 or psLen]
  of Leaf:
    let
      pSegm = vtx.lPfx.hexPrefixEncode(isleaf = true)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return BlobifyLeafPathOverflow
    data = vtx.lData.convertTo(Blob) & pSegm & @[0xC0u8 or psLen]

proc blobify*(vtx: VertexRef): Result[Blob, AristoError] =
  ## Variant of `blobify()`
  var
    data: Blob
    info = vtx.blobify data
  if info != AristoError(0):
    return err(info)
  ok(data)


proc blobify*(vGen: openArray[VertexID]; data: var Blob) =
  ## This function serialises the key generator used in the `AristoDb`
  ## descriptor.
  ##
  ## This data record is supposed to be as in a dedicated slot in the
  ## persistent tables.
  ## ::
  ##   Admin:
  ##     uint64, ...    -- list of IDs
  ##     0x40
  ##
  data.setLen(0)
  for w in vGen:
    data &= w.uint64.toBytesBE.toSeq
  data.add 0x40u8

proc blobify*(vGen: openArray[VertexID]): Blob =
  ## Variant of `blobify()`
  vGen.blobify result


proc deblobify*(record: Blob; vtx: var VertexRef): AristoError =
  ## De-serialise a data record encoded with `blobify()`. The second
  ## argument `vtx` can be `nil`.
  if record.len < 3:                                  # minimum `Leaf` record
    return DeblobTooShort

  case record[^1] shr 6:
  of 0: # `Branch` vertex
    if record.len < 19:                               # at least two edges
      return DeblobBranchTooShort
    if (record.len mod 8) != 3:
      return DeblobBranchSizeGarbled
    let
      maxOffset = record.len - 11
      aInx = record.len - 3
      aIny = record.len - 2
    var
      offs = 0
      access = uint16.fromBytesBE record[aInx..aIny]  # bitmap
      vtxList: array[16,VertexID]
    while access != 0:
      if maxOffset < offs:
        return DeblobBranchInxOutOfRange
      let n = access.firstSetBit - 1
      access.clearBit n
      vtxList[n] = (uint64.fromBytesBE record[offs ..< offs+8]).VertexID
      offs += 8
      # End `while`
    vtx = VertexRef(
      vType: Branch,
      bVid:  vtxList)

  of 2: # `Extension` vertex
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rlen = record.len - 1                           # `vertexID` + path segm
    if record.len < 10:
      return DeblobExtTooShort
    if 8 + sLen != rlen:                              # => slen is at least 1
      return DeblobExtSizeGarbled
    let (isLeaf, pathSegment) = hexPrefixDecode record[8 ..< rLen]
    if isLeaf:
      return DeblobExtGotLeafPrefix
    vtx = VertexRef(
      vType: Extension,
      eVid:  (uint64.fromBytesBE record[0 ..< 8]).VertexID,
      ePfx:  pathSegment)

  of 3: # `Leaf` vertex
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rlen = record.len - 1                           # payload + path segment
      pLen = rLen - sLen                              # payload length
    if rlen < sLen:
      return DeblobLeafSizeGarbled
    let (isLeaf, pathSegment) = hexPrefixDecode record[pLen ..< rLen]
    if not isLeaf:
      return DeblobLeafGotExtPrefix
    vtx = VertexRef(
      vType:   Leaf,
      lPfx:    pathSegment,
      lData:   PayloadRef(
        pType: BlobData,
        blob:  record[0 ..< plen]))
  else:
    return DeblobUnknown

proc deblobify*(data: Blob; T: type VertexRef): Result[T,AristoError] =
  ## Variant of `deblobify()` for vertex deserialisation.
  var vtx = T(nil) # will be auto-initialised
  let info = data.deblobify vtx
  if info != AristoError(0):
    return err(info)
  ok vtx


proc deblobify*(data: Blob; vGen: var seq[VertexID]): AristoError =
  ## De-serialise the data record encoded with `blobify()` into the vertex ID
  ## generator argument `vGen`.
  if data.len == 0:
    vGen = @[]
  else:
    if (data.len mod 8) != 1:
      return DeblobSizeGarbled
    if data[^1] shr 6 != 1:
      return DeblobWrongType
    for n in 0 ..< (data.len div 8):
      let w = n * 8
      vGen.add (uint64.fromBytesBE data[w ..< w + 8]).VertexID

proc deblobify*(data: Blob; T: type seq[VertexID]): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising the vertex ID generator state
  var vGen: seq[VertexID]
  let info = data.deblobify vGen
  if info != AristoError(0):
    return err(info)
  ok vGen

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
