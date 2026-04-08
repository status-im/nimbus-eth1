# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
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
  eth/common/accounts,
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
  
template `&=`*(x: var VertexBuf, y: VertexBuf) =
  x.add(y.data)

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
  # TODO evaluate an encoding that colocates short roots (like STATE_ROOT_VID) with
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

  var tmp = 0'u64
  let start = 8 - data.len
  for i in 0..<data.len:
    tmp += uint64(data[i]) shl (8*(7-(i + start)))

  ok T(tmp)

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

proc blobifyTo*(pyl: AccLeafRef, data: var VertexBuf) =
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

proc blobifyTo*(pyl: StoLeafRef, data: var VertexBuf) =
  data &= pyl.stoData.blobify().data
  data &= [0x20.byte]

func deblobifyPfx*(record: openArray[byte]): Result[NibblesBuf, AristoError] =
  if record.len < 3:
    return err(DeblobVtxTooShort)

  let psLen = int(record[^1] and 0b00111111)

  if psLen == 0:
    return ok default(NibblesBuf)

  let psPos = record.len - psLen - 1
  if psPos < 0 or psLen > record.len - 2:
    return err(DeblobVtxTooShort)

  let (_, pathSegment) =
    NibblesBuf.fromHexPrefix record.toOpenArray(psPos, record.len - 2)

  ok pathSegment

template pfx*(vtx: VertexBuf): NibblesBuf =
  vtx.data().deblobifyPfx().expect("valid vertex")

proc blobifyTo*(vtx: VertexRef, key: HashKey, data: var VertexBuf) =
  ## This function serialises the vertex argument to a database record.
  ## Contrary to RLP based serialisation, these records aim to align on
  ## fixed byte boundaries.
  ## ::
  ##   Branch:
  ##     <HashKey>      -- optional hash key
  ##     startVid       -- vid of first child vertex
  ##     used           -- bitmap of which children are included
  ##     seq[byte]      -- hex encoded partial path (non-empty for extension nodes)
  ##     0xtt + xx      -- bits + pathSegmentLen(6)
  ##
  ##   Leaf:
  ##     seq[byte]      -- opaque leaf data payload (might be zero length)
  ##     seq[byte]      -- hex encoded partial path (at least one byte)
  ##     0xtt + yy      -- bits + partialPathLen(6)
  ##

  doAssert vtx.isValid

  template writePfx(vtx, bits: untyped): untyped =
    if vtx.pfx.len >= 0:
      let pSegm = vtx.pfx.toHexPrefix(isleaf = vtx.vType in Leaves)
      data &= pSegm.data()
      (bits shl 6) or pSegm.len.byte
    else:
      (bits shl 6)

  let bits =
    case vtx.vType
    of Branches:
      let
        vtx = BranchRef(vtx)
        bits =
          if key.isValid and key.len == 32:
            # Shorter keys can be loaded from the vertex directly
            data.add key.data()
            0b10'u8
          else:
            0b00'u8

      data.add vtx.startVid.blobify().data()
      data.add toBytesBE(vtx.used)
      if vtx.vType == ExtBranch:
        writePfx(ExtBranchRef(vtx), bits)
      else:
        bits shl 6
    of AccLeaf:
      let vtx = AccLeafRef(vtx)
      vtx.blobifyTo(data)
      writePfx(vtx, 0b01'u8)
    of StoLeaf:
      let vtx = StoLeafRef(vtx)
      vtx.blobifyTo(data)
      writePfx(vtx, 0b01'u8)

  data &= [bits]

template blobify*(vtx: VertexRef, key: HashKey): openArray[byte] =
  var vtxBuf: VertexBuf
  vtx.blobifyTo(key, vtxBuf)
  vtxBuf.data()

proc blobifyTo*(lSst: SavedState; data: var seq[byte]) =
  ## Serialise a last saved state record
  data.add lSst.vTop.uint64.toBytesBE
  data.add lSst.serial.toBytesBE
  data.add @[0x7fu8]

proc blobify*(lSst: SavedState): seq[byte] =
  ## Variant of `blobify()`
  var data: seq[byte]
  lSst.blobifyTo data
  data

proc deblobifyBranch*(
    record: openArray[byte];
      ): Result[(VertexID, uint16), AristoError] =
  if record.len < 3:
    return err(DeblobBranchTooShort)

  let
    hasKey = ((record[^1] shr 6) and 0b10'u8) > 0
    psLen  = int(record[^1] and 0b00111111)
    start  = if hasKey: 32 else: 0
    psPos  = record.len - psLen - 1     # first byte of path segment
    svLen  = psPos - start - 2          # length of the startVid blob

  if svLen < 1 or svLen > 8:
    return err(DeblobBranchTooShort)

  var pos = start
  let
    startVid = VertexID(?load64(record, pos, svLen))
    used     = uint16.fromBytesBE(record.toOpenArray(pos, pos + 1))

  ok (startVid, used)

proc deblobifyStoLeaf*(
    data: openArray[byte];
      ): Result[UInt256,AristoError] =
  assert data.len > 0
  let mask = data[^1]
  assert (mask and 0x20) > 0

  deblobify(data.toOpenArray(0, data.len - 2), UInt256)

proc deblobifyStoLeaf*(
    vtxBuf: VertexBuf;
      ): Result[UInt256,AristoError] =   
  let
    bits = vtxBuf[^1] shr 6
    hasKey = (bits and 0b10'u8) > 0
    psLen = int(vtxBuf[^1] and 0b00111111)
    start = if hasKey: 32 else: 0
    psPos = vtxBuf.len - psLen - 1

  vtxBuf.data().toOpenArray(start, psPos - 1).deblobifyStoLeaf()

proc deblobifyAccLeaf*(
    data: openArray[byte];
      ): Result[(AristoAccount, StorageID),AristoError] =
  assert data.len > 0
  let mask = data[^1]
  assert (mask and 0xf0) == 0
  
  var
    account: AristoAccount
    stoID: StorageID
    start = 0
    lens = uint16.fromBytesBE(data.toOpenArray(data.len - 3, data.len - 2))

  if (mask and 0x01) > 0:
    let len = lens and 0b111
    account.nonce = ?load64(data, start, int(len + 1))

  if (mask and 0x02) > 0:
    let len = (lens shr 3) and 0b11111
    account.balance = ?load256(data, start, int(len + 1))

  if (mask and 0x04) > 0:
    let len = (lens shr 8) and 0b111
    stoID = (true, VertexID(?load64(data, start, int(len + 1))))

  if (mask and 0x08) > 0:
    if data.len() < start + 32:
      return err(DeblobCodeLenUnsupported)
    discard account.codeHash.data.copyFrom(data.toOpenArray(start, start + 31))
  else:
    account.codeHash = EMPTY_CODE_HASH

  ok (account, stoID)

proc deblobifyAccLeaf*(
    vtxBuf: VertexBuf;
      ): Result[(AristoAccount, StorageID),AristoError] =
  let
    bits = vtxBuf[^1] shr 6
    hasKey = (bits and 0b10'u8) > 0
    psLen = int(vtxBuf[^1] and 0b00111111)
    start = if hasKey: 32 else: 0
    psPos = vtxBuf.len - psLen - 1

  vtxBuf.data().toOpenArray(start, psPos - 1).deblobifyAccLeaf()

proc deblobifyLeaf(
    data: openArray[byte];
    pfx: NibblesBuf;
      ): Result[VertexRef, AristoError] =
  if data.len == 0:
    return err(DeblobVtxTooShort)

  let mask = data[^1]
  if (mask and 0x20) > 0: # Slot storage data
    ok StoLeafRef.init(
      pfx,
      ?deblobify(data.toOpenArray(0, data.len - 2), UInt256),
    )
  elif (mask and 0xf0) == 0: # Only account fields set
    let vtx = AccLeafRef(vType: AccLeaf, pfx: pfx)
    var
      start = 0
      lens = uint16.fromBytesBE(data.toOpenArray(data.len - 3, data.len - 2))

    if (mask and 0x01) > 0:
      let len = lens and 0b111
      vtx.account.nonce = ?load64(data, start, int(len + 1))

    if (mask and 0x02) > 0:
      let len = (lens shr 3) and 0b11111
      vtx.account.balance = ?load256(data, start, int(len + 1))

    if (mask and 0x04) > 0:
      let len = (lens shr 8) and 0b111
      vtx.stoID = (true, VertexID(?load64(data, start, int(len + 1))))

    if (mask and 0x08) > 0:
      if data.len() < start + 32:
        return err(DeblobCodeLenUnsupported)
      discard vtx.account.codeHash.data.copyFrom(data.toOpenArray(start, start + 31))
    else:
      vtx.account.codeHash = EMPTY_CODE_HASH

    ok(vtx)
  else:
    err(DeblobUnknown)

proc deblobifyType*(record: openArray[byte]; T: type VertexRef):
    Result[VertexType, AristoError] =
  if record.len < 3:                                  # minimum `Leaf` record
    return err(DeblobVtxTooShort)

  let
    isLeaf = ((record[^1] shr 6) and 0b01'u8) > 0
    psLen = int(record[^1] and 0b00111111)
    psPos = record.len - psLen - 1
  ok if isLeaf:
    let mask = record[psPos - 1]
    if (mask and 0x20) > 0: StoLeaf else: AccLeaf
  else:
    if psLen > 0: ExtBranch else: Branch

proc deblobify*(
    record: openArray[byte];
    T: type VertexRef;
      ): Result[T,AristoError] =
  ## De-serialise a data record encoded with `blobify()`. The second
  ## argument `vtx` can be `nil`.
  if record.len < 3: # minimum `Leaf` record
    return err(DeblobVtxTooShort)

  let
    bits = record[^1] shr 6
    isLeaf = (bits and 0b01'u8) > 0
    hasKey = (bits and 0b10'u8) > 0
    psLen = int(record[^1] and 0b00111111)
    start = if hasKey: 32 else: 0

  if psLen > record.len - 2 or start > record.len - 2 - psLen:
    return err(DeblobBranchTooShort)

  let
    psPos = record.len - psLen - 1
    (_, pathSegment) =
      NibblesBuf.fromHexPrefix record.toOpenArray(psPos, record.len - 2)

  ok case isLeaf
  of false:
    var pos = start
    let
      svLen = psPos - pos - 2
      startVid = VertexID(?load64(record, pos, svLen))
      used = uint16.fromBytesBE(record.toOpenArray(pos, pos + 1))

    pos += 2

    if pathSegment.len > 0:
      ExtBranchRef.init(pathSegment, startVid, used)
    else:
      BranchRef.init(startVid, used)
  of true:
    ?record.toOpenArray(start, psPos - 1).deblobifyLeaf(pathSegment)

proc deblobify*(record: openArray[byte], T: type HashKey): Opt[HashKey] =
  if record.len > 33 and (((record[^1] shr 6) and 0b10'u8) > 0):
    HashKey.fromBytes(record.toOpenArray(0, 31))
  else:
    Opt.none(HashKey)

proc deblobify*(
    data: openArray[byte];
    T: type SavedState;
      ): Result[SavedState,AristoError] =
  ## De-serialise the last saved state data record previously encoded with
  ## `blobify()`.
  if data.len != 17:
    return err(DeblobWrongSize)
  if data[^1] != 0x7f:
    return err(DeblobWrongType)

  ok(SavedState(
    vTop: VertexID(uint64.fromBytesBE data.toOpenArray(0, 7)),
    serial: uint64.fromBytesBE data.toOpenArray(8, 15)))


func childVid*(record: openArray[byte]): Result[VertexID, AristoError] =
  ## Extract the child vertex ID that a recursive hash computation would need
  ## to descend into, operating directly on the serialised ``VertexBuf`` byte
  ## representation.  This mirrors the ``childVid(VertexRef)`` template from
  ## ``aristo_compute.nim`` but avoids the heap allocation of a full
  ## ``VertexRef`` deserialisation.
  ##
  ## Returns
  ## * ``startVid`` for Branch / ExtBranch vertices
  ## * ``stoID.vid`` for AccLeaf vertices that carry a valid storage root
  ## * ``default(VertexID)`` for StoLeaf vertices and AccLeaf without storage
  ##
  if record.len < 3:
    return err(DeblobVtxTooShort)

  let
    bits  = record[^1] shr 6
    isLeaf = (bits and 0b01'u8) > 0
    hasKey = (bits and 0b10'u8) > 0
    psLen  = int(record[^1] and 0b00111111)

  if not isLeaf:
    # ---- Branch / ExtBranch ----
    # Layout: [<HashKey 32>?] [startVid 1‑8] [used 2] [pfx psLen] [trailing 1]
    let
      start  = if hasKey: 32 else: 0
      psPos  = record.len - psLen - 1          # first byte of path segment
      svLen  = psPos - start - 2               # length of the startVid blob

    if svLen < 1 or svLen > 8 or start + svLen + 2 > record.len - psLen - 1:
      return err(DeblobBranchTooShort)

    var pos = start
    let startVid = ?load64(record, pos, svLen)  # advances pos past startVid
    ok VertexID(startVid)

  else:
    # ---- Leaf ----
    # Determine sub‑type from the mask byte that sits just before the hex‑
    # prefix (which is `psLen` bytes before the trailing byte).
    let psPos = record.len - psLen - 1  # first byte of path segment area
    let
      start = if hasKey: 32 else: 0     # always 0 for current leaf encoding
      #leafData = record.toOpenArray(start, psPos - 1)
      leafDataStart = start
      leafDataEnd = psPos
      leafDataLen = leafDataEnd - leafDataStart

    if leafDataLen == 0:
      return err(DeblobVtxTooShort)

    let mask = record[leafDataEnd - 1]

    if (mask and 0x20) > 0:
      # ---- StoLeaf ----
      # Storage leaves have no children.
      ok default(VertexID)

    elif (mask and 0xf0) == 0:
      # ---- AccLeaf ----
      # We only need the stoID field.  The payload preceding the 3‑byte
      # trailer (mask + lens) is laid out as:
      #   [nonce?] [balance?] [stoID.vid?] [codeHash?] [lens 2] [mask 1]
      #
      # `mask bit 0x04` → stoID is present
      # `(lens shr 8) and 0b111` → `stoID_byte_length − 1`
      if (mask and 0x04) == 0:
        # No storage ID → nothing to recurse into.
        return ok default(VertexID)

      let lens = uint16.fromBytesBE(
        record.toOpenArray(leafDataStart + leafDataLen - 3, leafDataStart + leafDataLen - 2))

      # Walk past nonce and balance to reach the stoID bytes.
      var pos = 0

      if (mask and 0x01) > 0:            # nonce present
        let nLen = int(lens and 0b111) + 1
        pos += nLen

      if (mask and 0x02) > 0:            # balance present
        let bLen = int((lens shr 3) and 0b11111) + 1
        pos += bLen

      # stoID bytes
      let sLen = int((lens shr 8) and 0b111) + 1
      if leafDataLen < pos + sLen + 3:   # +3 for lens(2) + mask(1) trailer
        return err(DeblobVtxTooShort)

      let stoVid = ?deblobify(
        record.toOpenArray(leafDataStart + pos, leafDataStart + pos + sLen - 1), uint64)
      ok VertexID(stoVid)

    else:
      err(DeblobUnknown)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
