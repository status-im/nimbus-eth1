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
  results,
  stew/[arrayops, endians2],
  ./aristo_desc

export aristo_desc, results

# Allocation-free version short big-endian encoding that skips the leading
# zeroes
type
  SbeBuf*[I] = object
    buf*: array[sizeof(I), byte]
    len*: byte

  RVidBuf* = object
    buf*: array[sizeof(SbeBuf[VertexID]) * 2, byte]
    len*: byte

func significantBytesBE(val: openArray[byte]): byte =
  for i in 0 ..< val.len:
    if val[i] != 0:
      return byte(val.len - i)
  return 1

func blobify*(v: VertexID|uint64): SbeBuf[typeof(v)] =
  let b = v.uint64.toBytesBE()
  SbeBuf[typeof(v)](buf: b, len: significantBytesBE(b))

func blobify*(v: StUint): SbeBuf[typeof(v)] =
  let b = v.toBytesBE()
  SbeBuf[typeof(v)](buf: b, len: significantBytesBE(b))

template data*(v: SbeBuf): openArray[byte] =
  let vv = v
  vv.buf.toOpenArray(vv.buf.len - int(vv.len), vv.buf.high)


func blobify*(rvid: RootedVertexID): RVidBuf =
  # Length-prefixed root encoding creates a unique and common prefix for all
  # verticies sharing the same root
  # TODO evaluate an encoding that colocates short roots (like VertexID(1)) with
  #      the length
  let root = rvid.root.blobify()
  result.buf[0] = root.len
  assign(result.buf.toOpenArray(1, root.len), root.data())

  if rvid.root == rvid.vid:
    result.len = root.len + 1
  else:
    # We can derive the length of the `vid` from the total length
    let vid = rvid.vid.blobify()
    assign(result.buf.toOpenArray(root.len + 1, root.len + vid.len), vid.data())
    result.len = root.len + 1 + vid.len

proc deblobify*[T: uint64|VertexID](data: openArray[byte], _: type T): Result[T,AristoError] =
  if data.len < 1 or data.len > 8:
    return err(Deblob64LenUnsupported)

  var tmp: array[8, byte]
  discard tmp.toOpenArray(8 - data.len, 7).copyFrom(data)

  ok T(uint64.fromBytesBE(tmp))

proc deblobify*(data: openArray[byte], _: type UInt256): Result[UInt256,AristoError] =
  if data.len < 1 or data.len > 32:
    return err(Deblob256LenUnsupported)

  ok UInt256.fromBytesBE(data)

func deblobify*(data: openArray[byte], T: type RootedVertexID): Result[T, AristoError] =
  let rlen = int(data[0])
  if data.len < 2:
    return err(DeblobRVidLenUnsupported)

  if data.len < rlen + 1:
    return err(DeblobRVidLenUnsupported)

  let
    root = ?deblobify(data.toOpenArray(1, rlen), VertexID)
    vid = if data.len > rlen + 1:
      ?deblobify(data.toOpenArray(rlen + 1, data.high()), VertexID)
    else:
      root
  ok (root, vid)

template data*(v: RVidBuf): openArray[byte] =
  let vv = v
  vv.buf.toOpenArray(0, vv.len - 1)

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc load64(data: openArray[byte]; start: var int, len: int): Result[uint64,AristoError] =
  if data.len < start + len:
    return err(Deblob256LenUnsupported)

  let val = ?deblobify(data.toOpenArray(start, start + len - 1), uint64)
  start += len
  ok val

proc load256(data: openArray[byte]; start: var int, len: int): Result[UInt256,AristoError] =
  if data.len < start + len:
    return err(Deblob256LenUnsupported)
  let val = ?deblobify(data.toOpenArray(start, start + len - 1), UInt256)
  start += len
  ok val

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc blobifyTo*(pyl: LeafPayload, data: var seq[byte]) =
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

    if pyl.stoID.isValid:
      mask = mask or 0x04
      let tmp = pyl.stoID.vid.blobify()
      lens += uint16(tmp.len - 1) shl 8 # 3 bits
      data &= tmp.data()

    if pyl.account.codeHash != EMPTY_CODE_HASH:
      mask = mask or 0x08
      data &= pyl.account.codeHash.data

    data &= lens.toBytesBE()
    data &= [mask]
  of StoData:
    data &= pyl.stoData.blobify().data
    data &= [0x20.byte]

proc blobifyTo*(vtx: VertexRef; data: var seq[byte]): Result[void,AristoError] =
  ## This function serialises the vertex argument to a database record.
  ## Contrary to RLP based serialisation, these records aim to align on
  ## fixed byte boundaries.
  ## ::
  ##   Branch:
  ##     [VertexID, ..] -- list of up to 16 child vertices lookup keys
  ##     seq[byte]      -- hex encoded partial path (non-empty for extension nodes)
  ##     uint64         -- lengths of each child vertex, each taking 4 bits
  ##     0x80 + xx      -- marker(2) + pathSegmentLen(6)
  ##
  ##   Leaf:
  ##     seq[byte]      -- opaque leaf data payload (might be zero length)
  ##     seq[byte]      -- hex encoded partial path (at least one byte)
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

    let
      pSegm =
        if vtx.pfx.len > 0:
          vtx.pfx.toHexPrefix(isleaf = false)
        else:
          default(HexPrefixBuf)
      psLen = pSegm.len.byte
    if 33 < psLen:
      return err(BlobifyExtPathOverflow)

    data &= pSegm.data()
    data &= lens.toBytesBE
    data &= [0x80u8 or psLen]

  of Leaf:
    let
      pSegm = vtx.pfx.toHexPrefix(isleaf = true)
      psLen = pSegm.len.byte
    if psLen == 0 or 33 < psLen:
      return err(BlobifyLeafPathOverflow)
    vtx.lData.blobifyTo(data)
    data &= pSegm.data()
    data &= [0xC0u8 or psLen]

  ok()

proc blobify*(vtx: VertexRef): seq[byte] =
  ## Variant of `blobify()`
  result = newSeqOfCap[byte](128)
  if vtx.blobifyTo(result).isErr:
    result.setLen(0) # blobify only fails on invalid verticies

proc blobifyTo*(lSst: SavedState; data: var seq[byte]): Result[void,AristoError] =
  ## Serialise a last saved state record
  data.add lSst.key.data
  data.add lSst.serial.toBytesBE
  data.add @[0x7fu8]
  ok()

proc blobify*(lSst: SavedState): Result[seq[byte],AristoError] =
  ## Variant of `blobify()`
  var data: seq[byte]
  ? lSst.blobifyTo data
  ok(move(data))

# -------------
proc deblobify(
    data: openArray[byte];
    pyl: var LeafPayload;
      ): Result[void,AristoError] =
  if data.len == 0:
    pyl = LeafPayload(pType: RawData)
    return ok()

  let mask = data[^1]
  if (mask and 0x10) > 0: # unstructured payload
    pyl = LeafPayload(pType: RawData, rawBlob: data[0 .. ^2])
    return ok()

  if (mask and 0x20) > 0: # Slot storage data
    pyl = LeafPayload(
      pType: StoData,
      stoData: ?deblobify(data.toOpenArray(0, data.len - 2), UInt256))
    return ok()

  pyl = LeafPayload(pType: AccountData)
  var
    start = 0
    lens = uint16.fromBytesBE(data.toOpenArray(data.len - 3, data.len - 2))

  if (mask and 0x01) > 0:
    let len = lens and 0b111
    pyl.account.nonce = ? load64(data, start, int(len + 1))

  if (mask and 0x02) > 0:
    let len = (lens shr 3) and 0b11111
    pyl.account.balance = ? load256(data, start, int(len + 1))

  if (mask and 0x04) > 0:
    let len = (lens shr 8) and 0b111
    pyl.stoID = (true, VertexID(? load64(data, start, int(len + 1))))

  if (mask and 0x08) > 0:
    if data.len() < start + 32:
      return err(DeblobCodeLenUnsupported)
    discard pyl.account.codeHash.data.copyFrom(data.toOpenArray(start, start + 31))
  else:
    pyl.account.codeHash = EMPTY_CODE_HASH

  ok()

proc deblobify*(
    record: openArray[byte];
    T: type VertexRef;
      ): Result[T,AristoError] =
  ## De-serialise a data record encoded with `blobify()`. The second
  ## argument `vtx` can be `nil`.
  if record.len < 3:                                  # minimum `Leaf` record
    return err(DeblobVtxTooShort)

  ok case record[^1] shr 6:
  of 2: # `Branch` vertex
    if record.len < 11:                               # at least two edges
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

    let (isLeaf, pathSegment) =
      NibblesBuf.fromHexPrefix record.toOpenArray(offs, aInx - 1)
    if isLeaf:
      return err(DeblobBranchGotLeafPrefix)

      # End `while`
    VertexRef(
      vType: Branch,
      pfx:   pathSegment,
      bVid:  vtxList)

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
    let vtx = VertexRef(
      vType: Leaf,
      pfx:  pathSegment)

    ? record.toOpenArray(0, pLen - 1).deblobify(vtx.lData)
    vtx

  else:
    return err(DeblobUnknown)

proc deblobify*(
    data: openArray[byte];
    T: type SavedState;
      ): Result[SavedState,AristoError] =
  ## De-serialise the last saved state data record previously encoded with
  ## `blobify()`.
  if data.len != 41:
    return err(DeblobWrongSize)
  if data[^1] != 0x7f:
    return err(DeblobWrongType)

  ok(SavedState(
    key: Hash32(array[32, byte].initCopyFrom(data.toOpenArray(0, 31))),
    serial: uint64.fromBytesBE data.toOpenArray(32, 39)))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
