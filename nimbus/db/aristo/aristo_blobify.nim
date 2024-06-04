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
  std/bitops,
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

proc blobifyTo*(pyl: PayloadRef, data: var Blob) =
  if pyl.isNil:
    return
  case pyl.pType
  of RawData:
    data &= pyl.rawBlob
    data &= [0x6b.byte]
  of RlpData:
    data &= pyl.rlpBlob
    data &= @[0x6a.byte]

  of AccountData:
    var mask: byte
    if 0 < pyl.account.nonce:
      mask = mask or 0x01
      data &= pyl.account.nonce.uint64.toBytesBE

    if high(uint64).u256 < pyl.account.balance:
      mask = mask or 0x08
      data &= pyl.account.balance.toBytesBE
    elif 0 < pyl.account.balance:
      mask = mask or 0x04
      data &= pyl.account.balance.truncate(uint64).uint64.toBytesBE

    if VertexID(0) < pyl.account.storageID:
      mask = mask or 0x10
      data &= pyl.account.storageID.uint64.toBytesBE

    if pyl.account.codeHash != VOID_CODE_HASH:
      mask = mask or 0x80
      data &= pyl.account.codeHash.data

    data &= [mask]

proc blobifyTo*(vtx: VertexRef; data: var Blob): Result[void,AristoError] =
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
      pos = data.len
    for n in 0..15:
      if vtx.bVid[n].isValid:
        access = access or (1u16 shl n)
        data &= vtx.bVid[n].uint64.toBytesBE
    if data.len - pos < 16:
      return err(BlobifyBranchMissingRefs)
    data &= access.toBytesBE
    data &= [0x08u8]
  of Extension:
    let
      pSegm = vtx.ePfx.hexPrefixEncode(isleaf = false)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return err(BlobifyExtPathOverflow)
    if not vtx.eVid.isValid:
      return err(BlobifyExtMissingRefs)
    data &= vtx.eVid.uint64.toBytesBE
    data &= pSegm
    data &= [0x80u8 or psLen]
  of Leaf:
    let
      pSegm = vtx.lPfx.hexPrefixEncode(isleaf = true)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return err(BlobifyLeafPathOverflow)
    vtx.lData.blobifyTo(data)
    data &= pSegm
    data &= [0xC0u8 or psLen]
  ok()

proc blobify*(vtx: VertexRef): Result[Blob, AristoError] =
  ## Variant of `blobify()`
  var data: Blob
  ? vtx.blobifyTo data
  ok(move(data))


proc blobifyTo*(tuv: VertexID; data: var Blob) =
  ## This function serialises a top used vertex ID.
  data.setLen(9)
  let w = tuv.uint64.toBytesBE
  (addr data[0]).copyMem(unsafeAddr w[0], 8)
  data[8] = 0x7Cu8

proc blobify*(tuv: VertexID): Blob =
  ## Variant of `blobifyTo()`
  tuv.blobifyTo result


proc blobifyTo*(lSst: SavedState; data: var Blob) =
  ## Serialise a last saved state record
  data.setLen(0)
  data.add lSst.src.data
  data.add lSst.trg.data
  data.add lSst.serial.toBytesBE
  data.add @[0x7fu8]

proc blobify*(lSst: SavedState): Blob =
  ## Variant of `blobify()`
  lSst.blobifyTo result

# -------------

proc deblobifyTo(
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

proc deblobifyTo*(
    record: openArray[byte];
    vtx: var VertexRef;
      ): Result[void,AristoError] =
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
    ? record.toOpenArray(0, pLen - 1).deblobifyTo(pyl)
    vtx = VertexRef(
      vType: Leaf,
      lPfx:  pathSegment,
      lData: pyl)

  else:
    return err(DeblobUnknown)
  ok()

proc deblobify*(
    data: openArray[byte];
    T: type VertexRef;
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for vertex deserialisation.
  var vtx = T(nil) # will be auto-initialised
  ? data.deblobifyTo vtx
  ok vtx


proc deblobifyTo*(
    data: openArray[byte];
    tuv: var VertexID;
      ): Result[void,AristoError] =
  ## De-serialise a top level vertex ID.
  if data.len == 0:
    tuv = VertexID(0)
  elif data.len != 9:
    return err(DeblobSizeGarbled)
  elif data[^1] != 0x7c:
    return err(DeblobWrongType)
  else:
    tuv = (uint64.fromBytesBE data.toOpenArray(0, 7)).VertexID
  ok()

proc deblobify*(
    data: openArray[byte];
    T: type VertexID;
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising a top level vertex ID.
  var vTop: T
  ? data.deblobifyTo vTop
  ok move(vTop)


proc deblobifyTo*(
    data: openArray[byte];
    lSst: var SavedState;
      ): Result[void,AristoError] =
  ## De-serialise the last saved state data record previously encoded with
  ## `blobify()`.
  if data.len != 73:
    return err(DeblobWrongSize)
  if data[^1] != 0x7f:
    return err(DeblobWrongType)
  func loadHashKey(data: openArray[byte]): Result[HashKey,AristoError] =
    var w = HashKey.fromBytes(data).valueOr:
      return err(DeblobHashKeyExpected)
    ok move(w)
  lSst.src = ? data.toOpenArray(0, 31).loadHashKey()
  lSst.trg = ? data.toOpenArray(32, 63).loadHashKey()
  lSst.serial = uint64.fromBytesBE data.toOpenArray(64, 71)
  ok()

proc deblobify*(
    data: openArray[byte];
    T: type SavedState;
      ): Result[T,AristoError] =
  ## Variant of `deblobify()` for deserialising a last saved state data record
  var lSst: T
  ? data.deblobifyTo lSst
  ok move(lSst)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
