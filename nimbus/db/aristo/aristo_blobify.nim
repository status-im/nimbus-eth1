# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[bitops, sequtils, sets, tables],
  eth/[common, trie/nibbles],
  results,
  stew/endians2,
  ./aristo_desc

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc load64(data: openArray[byte]; start: var int): Result[uint64,AristoError] =
  if data.len < start + 9:
    return err(DeblobPayloadTooShortInt64)
  let val = uint64.fromBytesBE(data.toOpenArray(start, start + 7))
  start += 8
  ok val

proc load256(data: openArray[byte]; start: var int): Result[UInt256,AristoError] =
  if data.len < start + 33:
    return err(DeblobPayloadTooShortInt256)
  let val = UInt256.fromBytesBE(data.toOpenArray(start, start + 31))
  start += 32
  ok val

# ------------------------------------------------------------------------------
# Public functions
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
      result &= pyl.account.balance.toBytesBE.toSeq
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
      access = 0u16
      refs: Blob
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
    if psLen == 0 or 33 < psLen:
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
  ok(move(data))

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

proc blobify*(lSst: SavedState; data: var Blob) =
  ## Serialise a last saved state record
  data.setLen(73)
  (addr data[0]).copyMem(unsafeAddr lSst.src.data[0], 32)
  (addr data[32]).copyMem(unsafeAddr lSst.trg.data[0], 32)
  let w = lSst.serial.toBytesBE
  (addr data[64]).copyMem(unsafeAddr w[0], 8)
  data[72] = 0x7fu8

proc blobify*(lSst: SavedState): Blob =
  ## Variant of `blobify()`
  lSst.blobify result


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
  func blobify(lid: HashKey): Blob =
    let n = lid.len
    if n < 32: @[n.byte] & @(lid.data) & 0u8.repeat(31 - n) else: @(lid.data)

  if not filter.isValid:
    return err(BlobifyNilFilter)
  data.setLen(0)
  data &= filter.fid.uint64.toBytesBE.toSeq
  data &= @(filter.src.data)
  data &= @(filter.trg.data)

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
      keyMode = 0u                 # default: ignore that key
      vtxLen  = 0u                 # default: ignore that vertex
      keyBlob: Blob
      vtxBlob: Blob

    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      keyBlob = key.blobify
      keyMode = if key.len < 32: 0xc000_0000u else: 0x8000_0000u
    elif filter.kMap.hasKey vid:
      keyMode = 0x4000_0000u       # void hash key => considered deleted

    if vtx.isValid:
      ? vtx.blobify vtxBlob
      vtxLen = vtxBlob.len.uint
      if 0x3fff_ffff <= vtxLen:
        return err(BlobifyFilterRecordOverflow)
    else:
      vtxLen = 0x3fff_ffff         # nil vertex => considered deleted

    data &=
      (keyMode or vtxLen).uint32.toBytesBE.toSeq &
      vid.uint64.toBytesBE.toSeq &
      keyBlob &
      vtxBlob

  # Loop over remaining data from key table
  for vid in leftOver:
    n.inc
    var
      keyMode = 0u                 # present and usable
      keyBlob: Blob

    let key = filter.kMap.getOrVoid vid
    if key.isValid:
      keyBlob = key.blobify
      keyMode = if key.len < 32: 0xc000_0000u else: 0x8000_0000u
    else:
      keyMode = 0x4000_0000u       # void hash key => considered deleted

    data &=
      keyMode.uint32.toBytesBE.toSeq &
      vid.uint64.toBytesBE.toSeq &
      keyBlob

  data[76 ..< 80] = n.uint32.toBytesBE.toSeq
  data.add 0x7Du8
  ok()

proc blobify*(filter: FilterRef): Result[Blob, AristoError] =
  ## ...
  var data: Blob
  ? filter.blobify data
  ok move(data)

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

proc deblobify(
    data: openArray[byte];
    pyl: var PayloadRef;
      ): Result[void,AristoError] =
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

  pyl = pAcc
  ok()

proc deblobify*(record: openArray[byte]; vtx: var VertexRef): Result[void,AristoError] =
  ## De-serialise a data record encoded with `blobify()`. The second
  ## argument `vtx` can be `nil`.
  if record.len < 3:                                  # minimum `Leaf` record
    return err(DeblobVtxTooShort)

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
      access = uint16.fromBytesBE record.toOpenArray(aInx, aIny)  # bitmap
      vtxList: array[16,VertexID]
    while access != 0:
      if maxOffset < offs:
        return err(DeblobBranchInxOutOfRange)
      let n = access.firstSetBit - 1
      access.clearBit n
      vtxList[n] = (uint64.fromBytesBE record.toOpenArray(offs, offs + 7)).VertexID
      offs += 8
      # End `while`
    vtx = VertexRef(
      vType: Branch,
      bVid:  vtxList)

  of 2: # `Extension` vertex
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rLen = record.len - 1                           # `vertexID` + path segm
    if record.len < 10:
      return err(DeblobExtTooShort)
    if 8 + sLen != rLen:                              # => slen is at least 1
      return err(DeblobExtSizeGarbled)
    let (isLeaf, pathSegment) = hexPrefixDecode record.toOpenArray(8, rLen - 1)
    if isLeaf:
      return err(DeblobExtGotLeafPrefix)
    vtx = VertexRef(
      vType: Extension,
      eVid:  (uint64.fromBytesBE record.toOpenArray(0, 7)).VertexID,
      ePfx:  pathSegment)

  of 3: # `Leaf` vertex
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rLen = record.len - 1                           # payload + path segment
      pLen = rLen - sLen                              # payload length
    if rLen < sLen:
      return err(DeblobLeafSizeGarbled)
    let (isLeaf, pathSegment) = hexPrefixDecode record.toOpenArray(pLen, rLen-1)
    if not isLeaf:
      return err(DeblobLeafGotExtPrefix)
    var pyl: PayloadRef
    ? record.toOpenArray(0, pLen - 1).deblobify(pyl)
    vtx = VertexRef(
      vType: Leaf,
      lPfx:  pathSegment,
      lData: pyl)

  else:
    return err(DeblobUnknown)
  ok()

proc deblobify*(data: openArray[byte]; T: type VertexRef): Result[T,AristoError] =
  ## Variant of `deblobify()` for vertex deserialisation.
  var vtx = T(nil) # will be auto-initialised
  ? data.deblobify vtx
  ok vtx


proc deblobify*(
    data: openArray[byte];
    vGen: var seq[VertexID];
      ): Result[void,AristoError] =
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
      vGen.add (uint64.fromBytesBE data.toOpenArray(w, w+7)).VertexID
  ok()

proc deblobify*(
    data: openArray[byte];
    T: type seq[VertexID];
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising the vertex ID generator state
  var vGen: T
  ? data.deblobify vGen
  ok move(vGen)

proc deblobify*(
    data: openArray[byte];
    lSst: var SavedState;
      ): Result[void,AristoError] =
  ## De-serialise the last saved state data record previously encoded with
  ## `blobify()`.
  if data.len != 73:
    return err(DeblobWrongSize)
  if data[^1] != 0x7f:
    return err(DeblobWrongType)
  (addr lSst.src.data[0]).copyMem(unsafeAddr data[0], 32)
  (addr lSst.trg.data[0]).copyMem(unsafeAddr data[32], 32)
  lSst.serial = uint64.fromBytesBE data[64..72]
  ok()

proc deblobify*(
    data: openArray[byte];
    T: type SavedState;
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising a last saved state data record
  var lSst: T
  ? data.deblobify lSst
  ok move(lSst)


proc deblobify*(data: Blob; filter: var FilterRef): Result[void,AristoError] =
  ## De-serialise an Aristo DB filter object
  if data.len < 80: # minumum length 80 for an empty filter
    return err(DeblobFilterTooShort)
  if data[^1] != 0x7d:
    return err(DeblobWrongType)

  func deblob(data: openArray[byte]; shortKey: bool): Result[HashKey,void] =
    if shortKey:
      HashKey.fromBytes data.toOpenArray(1, min(int data[0],31))
    else:
      HashKey.fromBytes data

  let f = FilterRef()
  f.fid = (uint64.fromBytesBE data.toOpenArray(0, 7)).FilterID
  (addr f.src.data[0]).copyMem(unsafeAddr data[8], 32)
  (addr f.trg.data[0]).copyMem(unsafeAddr data[40], 32)

  let
    nVids = uint32.fromBytesBE data.toOpenArray(72, 75)
    nTriplets = uint32.fromBytesBE data.toOpenArray(76, 79)
    nTrplStart = (80 + nVids * 8).int

  if data.len < nTrplStart:
    return err(DeblobFilterGenTooShort)
  for n in 0 ..< nVids:
    let w = 80 + n * 8
    f.vGen.add (uint64.fromBytesBE data.toOpenArray(int w, int w+7)).VertexID

  var offs = nTrplStart
  for n in 0 ..< nTriplets:
    if data.len < offs + 12:
      return err(DeblobFilterTrpTooShort)

    let
      keyFlag = data[offs] shr 6
      vtxFlag = ((uint32.fromBytesBE data.toOpenArray(offs, offs+3)) and 0x3fff_ffff).int
      vLen = if vtxFlag == 0x3fff_ffff: 0 else: vtxFlag
    if keyFlag == 0 and vtxFlag == 0:
      return err(DeblobFilterTrpVtxSizeGarbled) # no blind records
    offs = offs + 4

    let vid = (uint64.fromBytesBE data.toOpenArray(offs, offs+7)).VertexID
    offs = offs + 8

    if data.len < offs + (1 < keyFlag).ord * 32 + vLen:
      return err(DeblobFilterTrpTooShort)

    if 1 < keyFlag:
      f.kMap[vid] = data.toOpenArray(offs, offs+31).deblob(keyFlag == 3).valueOr:
        return err(DeblobHashKeyExpected)
      offs = offs + 32
    elif keyFlag == 1:
      f.kMap[vid] = VOID_HASH_KEY

    if vtxFlag == 0x3fff_ffff:
      f.sTab[vid] = VertexRef(nil)
    elif 0 < vLen:
      var vtx: VertexRef
      ? data.toOpenArray(offs, offs + vLen - 1).deblobify vtx
      f.sTab[vid] = vtx
      offs = offs + vLen

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
        a = (uint64.fromBytesBE data.toOpenArray(w, w + 7)).QueueID
        b = (uint64.fromBytesBE data.toOpenArray(w + 8, w + 15)).QueueID
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
