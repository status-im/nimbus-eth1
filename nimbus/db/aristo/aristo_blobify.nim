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
  eth/common,
  results,
  stew/[arrayops, endians2],
  ./aristo_desc

# Allocation-free version of the RLP integer encoding, returning the shortest
# big-endian representation - to decode, the length must be known / stored
# elsewhere
type
  RlpBuf*[I] = object
    buf*: array[sizeof(I), byte]
    len*: byte

func significantBytesBE(val: openArray[byte]): byte =
  for i in 0 ..< val.len:
    if val[i] != 0:
      return byte(val.len - i)
  return 1

func blobify*(v: VertexID|uint64): RlpBuf[typeof(v)] =
  let b = v.uint64.toBytesBE()
  RlpBuf[typeof(v)](buf: b, len: significantBytesBE(b))

func blobify*(v: StUint): RlpBuf[typeof(v)] =
  let b = v.toBytesBE()
  RlpBuf[typeof(v)](buf: b, len: significantBytesBE(b))

template data*(v: RlpBuf): openArray[byte] =
  let vv = v
  vv.buf.toOpenArray(vv.buf.len - int(vv.len), vv.buf.high)


proc deblobify*[T: uint64|VertexID](data: openArray[byte], _: type T): Result[T,AristoError] =
  if data.len < 1 or data.len > 8:
    return err(DeblobPayloadTooShortInt64)

  var tmp: array[8, byte]
  discard tmp.toOpenArray(8 - data.len, 7).copyFrom(data)

  ok T(uint64.fromBytesBE(tmp))

proc deblobify*(data: openArray[byte], _: type UInt256): Result[UInt256,AristoError] =
  if data.len < 1 or data.len > 32:
    return err(DeblobPayloadTooShortInt256)

  ok UInt256.fromBytesBE(data)

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc load64(data: openArray[byte]; start: var int, len: int): Result[uint64,AristoError] =
  if data.len < start + len:
    return err(DeblobPayloadTooShortInt64)

  let val = ?deblobify(data.toOpenArray(start, start + len - 1), uint64)
  start += len
  ok val

proc load256(data: openArray[byte]; start: var int, len: int): Result[UInt256,AristoError] =
  if data.len < start + len:
    return err(DeblobPayloadTooShortInt256)
  let val = ?deblobify(data.toOpenArray(start, start + len - 1), UInt256)
  start += len
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
    data &= [0x10.byte]

  of AccountData:
    # `lens` holds `len-1` since `mask` filters out the zero-length case (which
    # allows saving 1 bit per length)
    var lens: uint16
    var mask: byte
    if 0 < pyl.account.nonce:
      mask = mask or 0x01
      let tmp = pyl.account.nonce.blobify()
      lens += tmp.len - 1 # 3 bits
      data &= tmp.data()

    if 0 < pyl.account.balance:
      mask = mask or 0x02
      let tmp = pyl.account.balance.blobify()
      lens += uint16(tmp.len - 1) shl 3 # 5 bits
      data &= tmp.data()

    if VertexID(0) < pyl.stoID:
      mask = mask or 0x04
      let tmp = pyl.stoID.blobify()
      lens += uint16(tmp.len - 1) shl 8 # 3 bits
      data &= tmp.data()

    if pyl.account.codeHash != EMPTY_CODE_HASH:
      mask = mask or 0x08
      data &= pyl.account.codeHash.data

    data &= lens.toBytesBE()
    data &= [mask]

proc blobifyTo*(vtx: VertexRef; data: var Blob): Result[void,AristoError] =
  ## This function serialises the vertex argument to a database record.
  ## Contrary to RLP based serialisation, these records aim to align on
  ## fixed byte boundaries.
  ## ::
  ##   Branch:
  ##     [VertexID, ...] -- list of up to 16 child vertices lookup keys
  ##     uint64          -- lengths of each child vertex, each taking 4 bits
  ##     0x08            -- marker(8)
  ##
  ##   Extension:
  ##     VertexID       -- child vertex lookup key
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
      lens = 0u64
      pos = data.len
    for n in 0..15:
      if vtx.bVid[n].isValid:
        let tmp = vtx.bVid[n].blobify()
        lens += uint64(tmp.len) shl (n * 4)
        data &= tmp.data()
    if data.len == pos:
      return err(BlobifyBranchMissingRefs)
    data &= lens.toBytesBE
    data &= [0x08u8]
  of Extension:
    let
      pSegm = vtx.ePfx.toHexPrefix(isleaf = false)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return err(BlobifyExtPathOverflow)
    if not vtx.eVid.isValid:
      return err(BlobifyExtMissingRefs)
    data &= vtx.eVid.blobify().data()
    data &= pSegm
    data &= [0x80u8 or psLen]
  of Leaf:
    let
      pSegm = vtx.lPfx.toHexPrefix(isleaf = true)
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

proc blobifyTo*(lSst: SavedState; data: var Blob): Result[void,AristoError] =
  ## Serialise a last saved state record
  data.add lSst.key.data
  data.add lSst.serial.toBytesBE
  data.add @[0x7fu8]
  ok()

proc blobify*(lSst: SavedState): Result[Blob,AristoError] =
  ## Variant of `blobify()`
  var data: Blob
  ? lSst.blobifyTo data
  ok(move(data))

# -------------
proc deblobifyTo(
    data: openArray[byte];
    pyl: var PayloadRef;
      ): Result[void,AristoError] =
  if data.len == 0:
    pyl = PayloadRef(pType: RawData)
    return ok()

  let mask = data[^1]
  if (mask and 0x10) > 0: # unstructured payload
    pyl = PayloadRef(pType: RawData, rawBlob: data[0 .. ^2])
    return ok()

  var
    pAcc = PayloadRef(pType: AccountData)
    start = 0
    lens = uint16.fromBytesBE(data.toOpenArray(data.len - 3, data.len - 2))

  if (mask and 0x01) > 0:
    let len = lens and 0b111
    pAcc.account.nonce = ? load64(data, start, int(len + 1))

  if (mask and 0x02) > 0:
    let len = (lens shr 3) and 0b11111
    pAcc.account.balance = ? load256(data, start, int(len + 1))

  if (mask and 0x04) > 0:
    let len = (lens shr 8) and 0b111
    pAcc.stoID = VertexID(? load64(data, start, int(len + 1)))

  if (mask and 0x08) > 0:
    discard pAcc.account.codeHash.data.copyFrom(data.toOpenArray(start, start + 31))
  else:
    pAcc.account.codeHash = EMPTY_CODE_HASH


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
    if record.len < 12:                               # at least two edges
      return err(DeblobBranchTooShort)
    let
      aInx = record.len - 9
      aIny = record.len - 2
    var
      offs = 0
      lens = uint64.fromBytesBE record.toOpenArray(aInx, aIny)  # bitmap
      vtxList: array[16,VertexID]
      n = 0
    while lens != 0:
      let len = lens and 0b1111
      if len > 0:
        vtxList[n] = VertexID(? load64(record, offs, int(len)))
      inc n
      lens = lens shr 4

      # End `while`
    vtx = VertexRef(
      vType: Branch,
      bVid:  vtxList)

  of 2: # `Extension` vertex
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rLen = record.len - 1                           # `vertexID` + path segm
      pLen = rLen - sLen                              # payload length
    if rLen < sLen or pLen < 1:
      return err(DeblobLeafSizeGarbled)
    let (isLeaf, pathSegment) =
      NibblesBuf.fromHexPrefix record.toOpenArray(pLen, rLen - 1)
    if isLeaf:
      return err(DeblobExtGotLeafPrefix)

    var offs = 0
    vtx = VertexRef(
      vType: Extension,
      eVid:  VertexID(?load64(record, offs, pLen)),
      ePfx:  pathSegment)

  of 3: # `Leaf` vertex
    let
      sLen = record[^1].int and 0x3f                  # length of path segment
      rLen = record.len - 1                           # payload + path segment
      pLen = rLen - sLen                              # payload length
    if rLen < sLen or pLen < 1:
      return err(DeblobLeafSizeGarbled)
    let (isLeaf, pathSegment) =
      NibblesBuf.fromHexPrefix record.toOpenArray(pLen, rLen-1)
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
    lSst: var SavedState;
      ): Result[void,AristoError] =
  ## De-serialise the last saved state data record previously encoded with
  ## `blobify()`.
  # Keep that legacy setting for a while
  if data.len == 73:
    if data[^1] != 0x7f:
      return err(DeblobWrongType)
    lSst.key = EMPTY_ROOT_HASH
    lSst.serial = uint64.fromBytesBE data.toOpenArray(64, 71)
    return ok()
  # -----
  if data.len != 41:
    return err(DeblobWrongSize)
  if data[^1] != 0x7f:
    return err(DeblobWrongType)
  (addr lSst.key.data[0]).copyMem(unsafeAddr data[0], 32)
  lSst.serial = uint64.fromBytesBE data.toOpenArray(32, 39)
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
