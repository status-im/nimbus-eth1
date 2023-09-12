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
  std/[bitops, sequtils, sets],
  eth/[common, rlp, trie/nibbles],
  results,
  "."/[aristo_constants, aristo_desc]

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc aristoError(error: AristoError): NodeRef =
  ## Allows returning de
  NodeRef(vType: Leaf, error: error)

proc load64(data: Blob; start: var int): Result[uint64,AristoError] =
  if data.len < start + 9:
    return err(DeblobPayloadTooShortInt64)
  let val = uint64.fromBytesBE(data[start ..< start + 8])
  start += 8
  ok val

proc load256(data: Blob; start: var int): Result[UInt256,AristoError] =
  if data.len < start + 33:
    return err(DeblobPayloadTooShortInt256)
  let val = UInt256.fromBytesBE(data[start ..< start + 32])
  start += 32
  ok val

proc toPayloadBlob(node: NodeRef): Blob =
  ## Probably lossy conversion as the storage type `kind` gets missing
  let pyl = node.lData
  case pyl.pType:
  of RawData:
    result = pyl.rawBlob
  of RlpData:
    result = pyl.rlpBlob
  of AccountData:
    let key = if pyl.account.storageID.isValid: node.key[0] else: VOID_HASH_KEY
    result = rlp.encode Account(
      nonce:       pyl.account.nonce,
      balance:     pyl.account.balance,
      storageRoot: key.to(Hash256),
      codeHash:    pyl.account.codeHash)

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
        vType:     Leaf,
        lPfx:      pathSegment,
        lData:     PayloadRef(
          pType:   RawData,
          rawBlob: blobs[1]))
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
      writer.append node.toPayloadBlob

# ---------------------

proc to*(node: NodeRef; T: type HashKey): T =
  ## Convert the argument `node` to the corresponding Merkle hash key
  node.encode.digestTo T

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc blobify*(pyl: PayloadRef): Blob =
  if pyl.isNil:
    return
  case pyl.pType
  of RawData:
    result = pyl.rawBlob & @[0x6b.byte]
  of RlpData:
    result = pyl.rlpBlob & @[0x6a.byte]

  of AccountData:
    var mask: byte
    if 0 < pyl.account.nonce:
      mask = mask or 0x01
      result &= pyl.account.nonce.uint64.toBytesBE.toSeq

    if high(uint64).u256 < pyl.account.balance:
      mask = mask or 0x08
      result &= pyl.account.balance.UInt256.toBytesBE.toSeq
    elif 0 < pyl.account.balance:
      mask = mask or 0x04
      result &= pyl.account.balance.truncate(uint64).uint64.toBytesBE.toSeq

    if VertexID(0) < pyl.account.storageID:
      mask = mask or 0x10
      result &= pyl.account.storageID.uint64.toBytesBE.toSeq

    if pyl.account.codeHash != VOID_CODE_HASH:
      mask = mask or 0x80
      result &= pyl.account.codeHash.data.toSeq

    result &= @[mask]

proc blobify*(vtx: VertexRef; data: var Blob): Result[void,AristoError] =
  ## This function serialises the vertex argument to a database record.
  ## Contrary to RLP based serialisation, these records aim to align on
  ## fixed byte boundaries.
  ## ::
  ##   Branch:
  ##     uint64, ...    -- list of up to 16 child vertices lookup keys
  ##     uint16         -- index bitmap
  ##     0x08           -- marker(8)
  ##
  ##   Extension:
  ##     uint64         -- child vertex lookup key
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##     0x80 + xx      -- marker(2) + pathSegmentLen(6)
  ##
  ##   Leaf:
  ##     Blob           -- opaque leaf data payload (might be zero length)
  ##     Blob           -- hex encoded partial path (at least one byte)
  ##     0xc0 + yy      -- marker(2) + partialPathLen(6)
  ##
  ## For a branch record, the bytes of the `access` array indicate the position
  ## of the Patricia Trie vertex reference. So the `vertexID` with index `n` has
  ## ::
  ##   8 * n * ((access shr (n * 4)) and 15)
  ##
  if not vtx.isValid:
    return err(BlobifyNilVertex)
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
      return err(BlobifyBranchMissingRefs)
    data = refs & access.toBytesBE.toSeq & @[0x08u8]
  of Extension:
    let
      pSegm = vtx.ePfx.hexPrefixEncode(isleaf = false)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < pslen:
      return err(BlobifyExtPathOverflow)
    if not vtx.eVid.isValid:
      return err(BlobifyExtMissingRefs)
    data = vtx.eVid.uint64.toBytesBE.toSeq & pSegm & @[0x80u8 or psLen]
  of Leaf:
    let
      pSegm = vtx.lPfx.hexPrefixEncode(isleaf = true)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return err(BlobifyLeafPathOverflow)
    data = vtx.lData.blobify & pSegm & @[0xC0u8 or psLen]
  ok()


proc blobify*(vtx: VertexRef): Result[Blob, AristoError] =
  ## Variant of `blobify()`
  var data: Blob
  ? vtx.blobify data
  ok(data)

proc blobify*(vGen: openArray[VertexID]; data: var Blob) =
  ## This function serialises a list of vertex IDs.
  ## ::
  ##   uint64, ...    -- list of IDs
  ##   0x7c           -- marker(8)
  ##
  data.setLen(0)
  for w in vGen:
    data &= w.uint64.toBytesBE.toSeq
  data.add 0x7Cu8

proc blobify*(vGen: openArray[VertexID]): Blob =
  ## Variant of `blobify()`
  vGen.blobify result


proc blobify*(filter: FilterRef; data: var Blob): Result[void,AristoError] =
  ## This function serialises an Aristo DB filter object
  ## ::
  ##   uint64         -- filter ID
  ##   Uint256        -- source key
  ##   Uint256        -- target key
  ##   uint32         -- number of vertex IDs (vertex ID generator state)
  ##   uint32         -- number of (id,key,vertex) triplets
  ##
  ##   uint64, ...    -- list of vertex IDs (vertex ID generator state)
  ##
  ##   uint32         -- flag(3) + vtxLen(29), first triplet
  ##   uint64         -- vertex ID
  ##   Uint256        -- optional key
  ##   Blob           -- optional vertex
  ##
  ##   ...            -- more triplets
  ##   0x7d           -- marker(8)
  ##
  if not filter.isValid:
    return err(BlobifyNilFilter)
  data.setLen(0)
  data &= filter.fid.uint64.toBytesBE.toSeq
  data &= filter.src.ByteArray32.toSeq
  data &= filter.trg.ByteArray32.toSeq

  data &= filter.vGen.len.uint32.toBytesBE.toSeq
  data &= newSeq[byte](4) # place holder

  # Store vertex ID generator state
  for w in filter.vGen:
    data &= w.uint64.toBytesBE.toSeq

  var
    n = 0
    leftOver = filter.kMap.keys.toSeq.toHashSet

  # Loop over vertex table
  for (vid,vtx) in filter.sTab.pairs:
    n.inc
    leftOver.excl vid

    var
      keyMode = 0u                 # present and usable
      vtxMode = 0u                 # present and usable
      keyBlob: Blob
      vtxBlob: Blob

    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      keyBlob = key.ByteArray32.toSeq
    elif filter.kMap.hasKey vid:
      keyMode = 1u                 # void hash key => considered deleted
    else:
      keyMode = 2u                 # ignore that hash key

    if vtx.isValid:
      ? vtx.blobify vtxBlob
    else:
      vtxMode = 1u                 # nil vertex => considered deleted

    if (vtxBlob.len and not 0x1fffffff) != 0:
      return err(BlobifyFilterRecordOverflow)

    let pfx = ((keyMode * 3 + vtxMode) shl 29) or vtxBlob.len.uint
    data &=
      pfx.uint32.toBytesBE.toSeq &
      vid.uint64.toBytesBE.toSeq &
      keyBlob &
      vtxBlob

  # Loop over remaining data from key table
  for vid in leftOver:
    n.inc
    var
      mode = 2u                    # key present and usable, ignore vtx
      keyBlob: Blob

    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      keyBlob = key.ByteArray32.toSeq
    else:
      mode = 5u                    # 1 * 3 + 2: void key, ignore vtx

    let pfx = (mode shl 29)
    data &=
      pfx.uint32.toBytesBE.toSeq &
      vid.uint64.toBytesBE.toSeq &
      keyBlob

  data[76 ..< 80] = n.uint32.toBytesBE.toSeq
  data.add 0x7Du8
  ok()

proc blobify*(filter: FilterRef): Result[Blob, AristoError] =
  ## ...
  var data: Blob
  ? filter.blobify data
  ok data


proc blobify*(vFqs: openArray[(QueueID,QueueID)]; data: var Blob) =
  ## This function serialises a list of filter queue IDs.
  ## ::
  ##   uint64, ...    -- list of IDs
  ##   0x7e           -- marker(8)
  ##
  data.setLen(0)
  for w in vFqs:
    data &= w[0].uint64.toBytesBE.toSeq
    data &= w[1].uint64.toBytesBE.toSeq
  data.add 0x7Eu8

proc blobify*(vFqs: openArray[(QueueID,QueueID)]): Blob =
  ## Variant of `blobify()`
  vFqs.blobify result

# -------------

proc deblobify(data: Blob; pyl: var PayloadRef): Result[void,AristoError] =
  if data.len == 0:
    pyl = PayloadRef(pType: RawData)
    return ok()

  let mask = data[^1]
  if mask == 0x6b: # unstructured payload
    pyl = PayloadRef(pType: RawData, rawBlob: data[0 .. ^2])
    return ok()
  if mask == 0x6a: # RLP encoded payload
    pyl = PayloadRef(pType: RlpData, rlpBlob: data[0 .. ^2])
    return ok()

  var
    pAcc = PayloadRef(pType: AccountData)
    start = 0

  case mask and 0x03:
  of 0x00:
    discard
  of 0x01:
    pAcc.account.nonce = (? data.load64 start).AccountNonce
  else:
    return err(DeblobNonceLenUnsupported)

  case mask and 0x0c:
  of 0x00:
    discard
  of 0x04:
    pAcc.account.balance = (? data.load64 start).u256
  of 0x08:
    pAcc.account.balance = (? data.load256 start)
  else:
    return err(DeblobBalanceLenUnsupported)

  case mask and 0x30:
  of 0x00:
    discard
  of 0x10:
    pAcc.account.storageID = (? data.load64 start).VertexID
  else:
    return err(DeblobStorageLenUnsupported)

  case mask and 0xc0:
  of 0x00:
    pAcc.account.codeHash = VOID_CODE_HASH
  of 0x80:
    if data.len < start + 33:
      return err(DeblobPayloadTooShortInt256)
    (addr pAcc.account.codeHash.data[0]).copyMem(unsafeAddr data[start], 32)
  else:
    return err(DeblobCodeLenUnsupported)

  pyl = pacc
  ok()

proc deblobify*(record: Blob; vtx: var VertexRef): Result[void,AristoError] =
  ## De-serialise a data record encoded with `blobify()`. The second
  ## argument `vtx` can be `nil`.
  if record.len < 3:                                  # minimum `Leaf` record
    return err(DeblobTooShort)

  case record[^1] shr 6:
  of 0: # `Branch` vertex
    if record[^1] != 0x08u8:
      return err(DeblobUnknown)
    if record.len < 19:                               # at least two edges
      return err(DeblobBranchTooShort)
    if (record.len mod 8) != 3:
      return err(DeblobBranchSizeGarbled)
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
        return err(DeblobBranchInxOutOfRange)
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
      return err(DeblobExtTooShort)
    if 8 + sLen != rlen:                              # => slen is at least 1
      return err(DeblobExtSizeGarbled)
    let (isLeaf, pathSegment) = hexPrefixDecode record[8 ..< rLen]
    if isLeaf:
      return err(DeblobExtGotLeafPrefix)
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
      return err(DeblobLeafSizeGarbled)
    let (isLeaf, pathSegment) = hexPrefixDecode record[pLen ..< rLen]
    if not isLeaf:
      return err(DeblobLeafGotExtPrefix)
    var pyl: PayloadRef
    ? record[0 ..< plen].deblobify(pyl)
    vtx = VertexRef(
      vType: Leaf,
      lPfx:  pathSegment,
      lData: pyl)

  else:
    return err(DeblobUnknown)
  ok()

proc deblobify*(data: Blob; T: type VertexRef): Result[T,AristoError] =
  ## Variant of `deblobify()` for vertex deserialisation.
  var vtx = T(nil) # will be auto-initialised
  ? data.deblobify vtx
  ok vtx


proc deblobify*(data: Blob; vGen: var seq[VertexID]): Result[void,AristoError] =
  ## De-serialise the data record encoded with `blobify()` into the vertex ID
  ## generator argument `vGen`.
  if data.len == 0:
    vGen = @[]
  else:
    if (data.len mod 8) != 1:
      return err(DeblobSizeGarbled)
    if data[^1] != 0x7c:
      return err(DeblobWrongType)
    for n in 0 ..< (data.len div 8):
      let w = n * 8
      vGen.add (uint64.fromBytesBE data[w ..< w + 8]).VertexID
  ok()

proc deblobify*(data: Blob; T: type seq[VertexID]): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising the vertex ID generator state
  var vGen: seq[VertexID]
  ? data.deblobify vGen
  ok vGen

proc deblobify*(data: Blob; filter: var FilterRef): Result[void,AristoError] =
  ## De-serialise an Aristo DB filter object
  if data.len < 80: # minumum length 80 for an empty filter
    return err(DeblobFilterTooShort)
  if data[^1] != 0x7d:
    return err(DeblobWrongType)

  let f = FilterRef()
  f.fid = (uint64.fromBytesBE data[0 ..< 8]).FilterID
  (addr f.src.ByteArray32[0]).copyMem(unsafeAddr data[8], 32)
  (addr f.trg.ByteArray32[0]).copyMem(unsafeAddr data[40], 32)

  let
    nVids = uint32.fromBytesBE data[72 ..< 76]
    nTriplets = uint32.fromBytesBE data[76 ..< 80]
    nTrplStart = (80 + nVids * 8).int

  if data.len < nTrplStart:
    return err(DeblobFilterGenTooShort)
  for n in 0 ..< nVids:
    let w = 80 + n * 8
    f.vGen.add (uint64.fromBytesBE data[w ..< w + 8]).VertexID

  var offs = nTrplStart
  for n in 0 ..< nTriplets:
    if data.len < offs + 12:
      return err(DeblobFilterTrpTooShort)

    let
      flag = data[offs] shr 5 # double triplets: {0,1,2} x {0,1,2}
      vLen = ((uint32.fromBytesBE data[offs ..< offs + 4]) and 0x1fffffff).int
    if (vLen == 0) != ((flag mod 3) > 0):
      return err(DeblobFilterTrpVtxSizeGarbled) # contadiction
    offs = offs + 4

    let vid = (uint64.fromBytesBE data[offs ..< offs + 8]).VertexID
    offs = offs + 8

    if data.len < offs + (flag < 3).ord * 32 + vLen:
      return err(DeblobFilterTrpTooShort)

    if flag < 3:                                        # {0} x {0,1,2}
      var key: HashKey
      (addr key.ByteArray32[0]).copyMem(unsafeAddr data[offs], 32)
      f.kMap[vid] = key
      offs = offs + 32
    elif flag < 6:                                      # {0,1} x {0,1,2}
      f.kMap[vid] = VOID_HASH_KEY

    if 0 < vLen:
      var vtx: VertexRef
      ? data[offs ..< offs + vLen].deblobify vtx
      f.sTab[vid] = vtx
      offs = offs + vLen
    elif (flag mod 3) == 1:                             # {0,1,2} x {1}
      f.sTab[vid] = VertexRef(nil)

  if data.len != offs + 1:
    return err(DeblobFilterSizeGarbled)

  filter = f
  ok()

proc deblobify*(data: Blob; T: type FilterRef): Result[T,AristoError] =
  ##  Variant of `deblobify()` for deserialising an Aristo DB filter object
  var filter: T
  ? data.deblobify filter
  ok filter

proc deblobify*(
    data: Blob;
    vFqs: var seq[(QueueID,QueueID)];
      ): Result[void,AristoError] =
  ## De-serialise the data record encoded with `blobify()` into a filter queue
  ## ID argument liet `vFqs`.
  if data.len == 0:
    vFqs = @[]
  else:
    if (data.len mod 16) != 1:
      return err(DeblobSizeGarbled)
    if data[^1] != 0x7e:
      return err(DeblobWrongType)
    for n in 0 ..< (data.len div 16):
      let
        w = n * 16
        a = (uint64.fromBytesBE data[w + 0 ..< w + 8]).QueueID
        b = (uint64.fromBytesBE data[w + 8 ..< w + 16]).QueueID
      vFqs.add (a,b)
  ok()

proc deblobify*(
    data: Blob;
    T: type seq[(QueueID,QueueID)];
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising the vertex ID generator state
  var vFqs: seq[(QueueID,QueueID)]
  ? data.deblobify vFqs
  ok vFqs

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
