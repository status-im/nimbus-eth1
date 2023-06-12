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

proc aInit(key: var NodeKey; data: openArray[byte]): bool =
  ## Import argument `data` into `key` which must have length either `32`, or
  ## `0`. The latter case is equivalent to an all zero byte array of size `32`.
  if data.len == 32:
    (addr key.ByteArray32[0]).copyMem(unsafeAddr data[0], data.len)
    return true
  elif data.len == 0:
    key = VOID_NODE_KEY
    return true

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
      if not links[top].aInit(rlp.read(Blob)):
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
      if not node.key[0].aInit(blobs[1]):
        return aristoError(RlpExtPathEncoding)
      return node
  of 17:
    for n in [0,1]:
      if not links[n].aInit(blobs[n]):
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
  proc addNodeKey(writer: var RlpWriter; key: NodeKey) =
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
        writer.addNodeKey node.key[n]
      writer.append EmptyBlob
    of Extension:
      writer.startList(2)
      writer.append node.ePfx.hexPrefixEncode(isleaf = false)
      writer.addNodeKey node.key[0]
    of Leaf:
      writer.startList(2)
      writer.append node.lPfx.hexPrefixEncode(isleaf = true)
      writer.append node.lData.convertTo(Blob)

# ------------------------------------------------------------------------------
# Public db record transcoders
# ------------------------------------------------------------------------------

proc blobify*(node: VertexRef; data: var Blob): AristoError =
  ## This function serialises the node argument to a database record. Contrary
  ## to RLP based serialisation, these records aim to align on fixed byte
  ## boundaries.
  ## ::
  ##   Branch:
  ##     uint64, ...    -- list of up to 16 child nodes lookup keys
  ##     uint16         -- index bitmap
  ##     0x00           -- marker(2) + unused(2)
  ##
  ##   Extension:
  ##     uint64         -- child node lookup key
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##     0x80           -- marker(2) + unused(2)
  ##
  ##   Leaf:
  ##     Blob           -- opaque leaf data payload (might be zero length)
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##     0xc0           -- marker(2) + partialPathLen(6)
  ##
  ## For a branch record, the bytes of the `access` array indicate the position
  ## of the Patricia Trie node reference. So the `vertexID` with index `n` has
  ## ::
  ##   8 * n * ((access shr (n * 4)) and 15)
  ##
  case node.vType:
  of Branch:
    var
      top = 0u64
      access = 0u16
      refs: Blob
      keys: Blob
    for n in 0..15:
      if node.bVid[n].isValid:
        access = access or (1u16 shl n)
        refs &= node.bVid[n].uint64.toBytesBE.toSeq
    data = refs & access.toBytesBE.toSeq & @[0u8]
  of Extension:
    let
      pSegm = node.ePfx.hexPrefixEncode(isleaf = false)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < pslen:
      return VtxExPathOverflow
    data = node.eVid.uint64.toBytesBE.toSeq & pSegm & @[0x80u8 or psLen]
  of Leaf:
    let
      pSegm = node.lPfx.hexPrefixEncode(isleaf = true)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return VtxLeafPathOverflow
    data = node.lData.convertTo(Blob) & pSegm & @[0xC0u8 or psLen]

proc blobify*(node: VertexRef): Result[Blob, AristoError] =
  ## Variant of `blobify()`
  var
    data: Blob
    info = node.blobify data
  if info != AristoError(0):
    return err(info)
  ok(data)


proc blobify*(db: AristoDb; data: var Blob) =
  ## This function serialises some maintenance data for the `AristoDb`
  ## descriptor. At the moment, this contains the recycliing table for the
  ## `VertexID` values, only.
  ##
  ## This data recoed is supposed to be stored as the table value with the
  ## zero key for persistent tables.
  ## ::
  ##   Admin:
  ##     uint64, ...    -- list of IDs
  ##     0x40
  ##
  data.setLen(0)
  if not db.top.isNil:
    for w in db.top.vGen:
      data &= w.uint64.toBytesBE.toSeq
  data.add 0x40u8

proc blobify*(db: AristoDb): Blob =
  ## Variant of `toDescRecord()`
  db.blobify result


proc deblobify*(record: Blob; vtx: var VertexRef): AristoError =
  ## De-serialise a data record encoded with `blobify()`. The second
  ## argument `vtx` can be `nil`.
  if record.len < 3:                                  # minimum `Leaf` record
    return DbrTooShort

  case record[^1] shr 6:
  of 0: # `Branch` node
    if record.len < 19:                               # at least two edges
      return DbrBranchTooShort
    if (record.len mod 8) != 3:
      return DbrBranchSizeGarbled
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
        return DbrBranchInxOutOfRange
      let n = access.firstSetBit - 1
      access.clearBit n
      vtxList[n] = (uint64.fromBytesBE record[offs ..< offs+8]).VertexID
      offs += 8
      # End `while`
    vtx = VertexRef(
      vType: Branch,
      bVid:  vtxList)

  of 2: # `Extension` node
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rlen = record.len - 1                           # `vertexID` + path segm
    if record.len < 10:
      return DbrExtTooShort
    if 8 + sLen != rlen:                              # => slen is at least 1
      return DbrExtSizeGarbled
    let (isLeaf, pathSegment) = hexPrefixDecode record[8 ..< rLen]
    if isLeaf:
      return DbrExtGotLeafPrefix
    vtx = VertexRef(
      vType: Extension,
      eVid:  (uint64.fromBytesBE record[0 ..< 8]).VertexID,
      ePfx:  pathSegment)

  of 3: # `Leaf` node
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rlen = record.len - 1                           # payload + path segment
      pLen = rLen - sLen                              # payload length
    if rlen < sLen:
      return DbrLeafSizeGarbled
    let (isLeaf, pathSegment) = hexPrefixDecode record[pLen ..< rLen]
    if not isLeaf:
      return DbrLeafGotExtPrefix
    vtx = VertexRef(
      vType:   Leaf,
      lPfx:    pathSegment,
      lData:   PayloadRef(
        pType: BlobData,
        blob:  record[0 ..< plen]))
  else:
    return DbrUnknown


proc deblobify*(data: Blob; db: var AristoDb): AristoError =
  ## De-serialise the data record encoded with `blobify()` into a new current
  ## top layer. If present, the previous top layer of the `db` descriptor is
  ## pushed onto the parent layers stack.
  if not db.top.isNil:
    db.stack.add db.top
  db.top = AristoLayerRef()
  if data.len == 0:
    db.top.vGen = @[1.VertexID]
  else:
    if (data.len mod 8) != 1:
      return ADbGarbledSize
    if data[^1] shr 6 != 1:
      return ADbWrongType
    for n in 0 ..< (data.len div 8):
      let w = n * 8
      db.top.vGen.add (uint64.fromBytesBE data[w ..< w + 8]).VertexID

proc deblobify*[W: VertexRef|AristoDb](
    record: Blob;
    T: type W;
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for either `VertexRef` or `AristoDb`
  var obj: T # isNil, will be auto-initialised
  let info = record.deblobify obj
  if info != AristoError(0):
    return err(info)
  ok(obj)

proc deblobify*(record: Blob): Result[VertexRef,AristoError] =
  ## Default variant of `deblobify()` for `VertexRef`.
  record.deblobify VertexRef

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
