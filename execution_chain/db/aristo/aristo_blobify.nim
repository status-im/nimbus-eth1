# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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

proc blobifyTo*(pyl: LeafPayload, data: var seq[byte]) =
  case pyl.pType
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

proc blobifyTo*(vtx: VertexRef, key: HashKey, data: var seq[byte]) =
  ## This function serialises the vertex argument to a database record.
  ## Contrary to RLP based serialisation, these records aim to align on
  ## fixed byte boundaries.
  ## ::
  ##   Branch:
  ##     <HashKey>      -- optional hash key
  ##     [VertexID, ..] -- list of up to 16 child vertices lookup keys
  ##     seq[byte]      -- hex encoded partial path (non-empty for extension nodes)
  ##     uint64         -- lengths of each child vertex, each taking 4 bits
  ##     0x80 + xx      -- marker(0/2) + pathSegmentLen(6)
  ##
  ##   Leaf:
  ##     seq[byte]      -- opaque leaf data payload (might be zero length)
  ##     seq[byte]      -- hex encoded partial path (at least one byte)
  ##     0xc0 + yy      -- marker(3) + partialPathLen(6)
  ##
  ## For a branch record, the bytes of the `access` array indicate the position
  ## of the Patricia Trie vertex reference. So the `vertexID` with index `n` has
  ## ::
  ##   8 * n * ((access shr (n * 4)) and 15)
  ##
  doAssert vtx.isValid

  let
    bits =
      case vtx.vType
      of Branch:
        let bits =
          if key.isValid and key.len == 32:
            # Shorter keys can be loaded from the vertex directly
            data.add key.data()
            0b10'u8
          else:
            0b00'u8

        data.add vtx.startVid.blobify().data()
        data.add toBytesBE(vtx.used)
        bits
      of Leaf:
        vtx.lData.blobifyTo(data)
        0b01'u8

    pSegm =
      if vtx.pfx.len > 0:
        vtx.pfx.toHexPrefix(isleaf = vtx.vType == Leaf)
      else:
        default(HexPrefixBuf)
    psLen = pSegm.len.byte

  data &= pSegm.data()
  data &= [(bits shl 6) or psLen]

proc blobify*(vtx: VertexRef, key: HashKey): seq[byte] =
  ## Variant of `blobify()`
  result = newSeqOfCap[byte](128)
  vtx.blobifyTo(key, result)

proc blobifyTo*(lSst: SavedState; data: var seq[byte]) =
  ## Serialise a last saved state record
  data.add lSst.key.data
  data.add lSst.serial.toBytesBE
  data.add @[0x7fu8]

proc blobify*(lSst: SavedState): seq[byte] =
  ## Variant of `blobify()`
  var data: seq[byte]
  lSst.blobifyTo data
  data

# -------------
proc deblobify(
    data: openArray[byte];
    pyl: var LeafPayload;
      ): Result[void,AristoError] =
  if data.len == 0:
    return err(DeblobVtxTooShort)

  let mask = data[^1]
  if (mask and 0x20) > 0: # Slot storage data
    pyl = LeafPayload(
      pType: StoData,
      stoData: ?deblobify(data.toOpenArray(0, data.len - 2), UInt256))
    ok()
  elif (mask and 0xf0) == 0: # Only account fields set
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
  else:
    err(DeblobUnknown)

proc deblobifyType*(record: openArray[byte]; T: type VertexRef):
    Result[VertexType, AristoError] =
  if record.len < 3:                                  # minimum `Leaf` record
    return err(DeblobVtxTooShort)

  ok if ((record[^1] shr 6) and 0b01'u8) > 0:
    Leaf
  else:
    Branch

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
    vType = if (bits and 0b01'u8) > 0: Leaf else: Branch
    hasKey = (bits and 0b10'u8) > 0
    psLen = int(record[^1] and 0b00111111)
    start = if hasKey: 32 else: 0

  if psLen > record.len - 2 or start > record.len - 2 - psLen:
    return err(DeblobBranchTooShort)

  let
    psPos = record.len - psLen - 1
    (_, pathSegment) =
      NibblesBuf.fromHexPrefix record.toOpenArray(psPos, record.len - 2)

  ok case vType
  of Branch:
    var pos = start
    let
      svLen = psPos - pos - 2
      startVid = VertexID(?load64(record, pos, svLen))
      used = uint16.fromBytesBE(record.toOpenArray(pos, pos + 1))

    pos += 2

    VertexRef(vType: Branch, pfx: pathSegment, startVid: startVid, used: used)
  of Leaf:
    let vtx = VertexRef(vType: Leaf, pfx: pathSegment)

    ?record.toOpenArray(start, psPos - 1).deblobify(vtx.lData)
    vtx

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
