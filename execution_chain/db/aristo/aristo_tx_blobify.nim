# nimbus-eth1
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- transaction frame serialisation
## =============================================
##
## Serialises the delta recorded in a single `AristoTxRef` (sTab, kMap,
## accLeaves, stoLeaves, vTop, blockNumber) to a flat byte sequence so the
## frame can be stored in the KVT database and restored without replaying
## blocks.
##
## Wire format (all multi-byte integers big-endian):
##
##   version        : 1 byte  = 0x01
##   vTop           : 8 bytes
##   blockNumber    : 1 flag byte (0/1) + 8 value bytes
##   sTab_count     : 4 bytes
##   per sTab entry :
##     rvid_len     : 1 byte
##     rvid_blob    : rvid_len bytes   (from blobify(rvid).data)
##     is_nil       : 1 byte  (0 = deletion marker, 1 = present)
##     if present:
##       blob_len   : 2 bytes
##       blob       : blob_len bytes   (from blobifyTo(vtx, key, data))
##   accLeaves_count: 4 bytes
##   per accLeaf entry:
##     hash         : 32 bytes
##     is_nil       : 1 byte
##     if present:
##       blob_len   : 2 bytes
##       blob       : blob_len bytes   (from blobifyTo(vtxRef, VOID, data))
##   stoLeaves_count: 4 bytes
##   per stoLeaf entry:
##     <same layout as accLeaf entries>
##
## The kMap is implicitly embedded: `blobifyTo(vtx, key, data)` encodes the
## HashKey inside the blob when it is valid; `deblobify(record, HashKey)`
## recovers it.  No separate kMap section is needed.

{.push raises: [].}

import
  std/tables,
  stew/endians2,
  results,
  ./aristo_desc,
  ./aristo_blobify

export results

const TX_FRAME_VERSION = 0x01'u8

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

template readU8(data: openArray[byte]; pos: var int): byte =
  if pos >= data.len: return err(DeblobTxFrameTruncated)
  let v = data[pos]
  inc pos
  v

template readU16BE(data: openArray[byte]; pos: var int): uint16 =
  if pos + 1 >= data.len: return err(DeblobTxFrameTruncated)
  let v = uint16.fromBytesBE(data.toOpenArray(pos, pos + 1))
  pos += 2
  v

template readU32BE(data: openArray[byte]; pos: var int): uint32 =
  if pos + 3 >= data.len: return err(DeblobTxFrameTruncated)
  let v = uint32.fromBytesBE(data.toOpenArray(pos, pos + 3))
  pos += 4
  v

template readU64BE(data: openArray[byte]; pos: var int): uint64 =
  if pos + 7 >= data.len: return err(DeblobTxFrameTruncated)
  let v = uint64.fromBytesBE(data.toOpenArray(pos, pos + 7))
  pos += 8
  v

# ------------------------------------------------------------------------------
# Public: serialise
# ------------------------------------------------------------------------------

proc blobifyTxFrame*(tx: AristoTxRef): seq[byte] =
  var buf: seq[byte]

  buf.add TX_FRAME_VERSION
  buf.add tx.vTop.uint64.toBytesBE

  if tx.blockNumber.isSome:
    buf.add 0x01'u8
    buf.add tx.blockNumber.unsafeGet.toBytesBE
  else:
    buf.add 0x00'u8
    buf.add 0'u64.toBytesBE

  buf.add tx.sTab.len.uint32.toBytesBE
  for rvid, vtx in tx.sTab:
    let rvidb = blobify(rvid)
    buf.add rvidb.len.byte
    buf.add rvidb.data()

    if vtx.isNil:
      buf.add 0x00'u8
    else:
      buf.add 0x01'u8
      let key = tx.kMap.getOrDefault(rvid, VOID_HASH_KEY)
      var vtxBuf: VertexBuf
      vtx.blobifyTo(key, vtxBuf)
      buf.add vtxBuf.len.uint16.toBytesBE
      buf.add vtxBuf.data()

  buf.add tx.accLeaves.len.uint32.toBytesBE
  for accPath, leaf in tx.accLeaves:
    buf.add accPath.data
    if leaf.isNil:
      buf.add 0x00'u8
    else:
      buf.add 0x01'u8
      var vtxBuf: VertexBuf
      VertexRef(leaf).blobifyTo(VOID_HASH_KEY, vtxBuf)
      buf.add vtxBuf.len.uint16.toBytesBE
      buf.add vtxBuf.data()

  buf.add tx.stoLeaves.len.uint32.toBytesBE
  for stoPath, leaf in tx.stoLeaves:
    buf.add stoPath.data
    if leaf.isNil:
      buf.add 0x00'u8
    else:
      buf.add 0x01'u8
      var vtxBuf: VertexBuf
      VertexRef(leaf).blobifyTo(VOID_HASH_KEY, vtxBuf)
      buf.add vtxBuf.len.uint16.toBytesBE
      buf.add vtxBuf.data()

  buf

# ------------------------------------------------------------------------------
# Public: deserialise
# ------------------------------------------------------------------------------

type TxFrameData* = object
  vTop*:        VertexID
  blockNumber*: Opt[uint64]
  sTab*:        Table[RootedVertexID, VertexRef]
  kMap*:        Table[RootedVertexID, HashKey]
  accLeaves*:   Table[Hash32, AccLeafRef]
  stoLeaves*:   Table[Hash32, StoLeafRef]

proc deblobifyTxFrame*(
    data: openArray[byte]
): Result[TxFrameData, AristoError] =
  var pos = 0

  let version = readU8(data, pos)
  if version != TX_FRAME_VERSION:
    return err(DeblobTxFrameVersion)

  var res: TxFrameData
  res.vTop = VertexID(readU64BE(data, pos))

  let bnFlag = readU8(data, pos)
  let bnVal  = readU64BE(data, pos)
  res.blockNumber = if bnFlag != 0: Opt.some(bnVal) else: Opt.none(uint64)

  let sTabCount = readU32BE(data, pos)
  res.sTab = initTable[RootedVertexID, VertexRef](int(sTabCount))
  res.kMap = initTable[RootedVertexID, HashKey](int(sTabCount))
  for _ in 0 ..< sTabCount:
    let rvidLen = int(readU8(data, pos))
    if pos + rvidLen - 1 >= data.len:
      return err(DeblobTxFrameTruncated)
    let rvid = ?deblobify(data.toOpenArray(pos, pos + rvidLen - 1), RootedVertexID)
    pos += rvidLen

    if readU8(data, pos) == 0x00:
      res.sTab[rvid] = nil
    else:
      let blobLen = int(readU16BE(data, pos))
      if pos + blobLen - 1 >= data.len:
        return err(DeblobTxFrameTruncated)
      let blobEnd = pos + blobLen - 1
      let vtx = ?deblobify(data.toOpenArray(pos, blobEnd), VertexRef)
      let key = deblobify(data.toOpenArray(pos, blobEnd), HashKey)
      pos += blobLen
      res.sTab[rvid] = vtx
      if key.isSome:
        res.kMap[rvid] = key.unsafeGet

  let accCount = readU32BE(data, pos)
  res.accLeaves = initTable[Hash32, AccLeafRef](int(accCount))
  for _ in 0 ..< accCount:
    if pos + 31 >= data.len:
      return err(DeblobTxFrameTruncated)
    let h = Hash32.copyFrom(data.toOpenArray(pos, pos + 31))
    pos += 32
    if readU8(data, pos) == 0x00:
      res.accLeaves[h] = nil
    else:
      let blobLen = int(readU16BE(data, pos))
      if pos + blobLen - 1 >= data.len:
        return err(DeblobTxFrameTruncated)
      let vtx = ?deblobify(data.toOpenArray(pos, pos + blobLen - 1), VertexRef)
      pos += blobLen
      if vtx.vType != AccLeaf:
        return err(DeblobUnknown)
      res.accLeaves[h] = AccLeafRef(vtx)

  let stoCount = readU32BE(data, pos)
  res.stoLeaves = initTable[Hash32, StoLeafRef](int(stoCount))
  for _ in 0 ..< stoCount:
    if pos + 31 >= data.len:
      return err(DeblobTxFrameTruncated)
    let h = Hash32.copyFrom(data.toOpenArray(pos, pos + 31))
    pos += 32
    if readU8(data, pos) == 0x00:
      res.stoLeaves[h] = nil
    else:
      let blobLen = int(readU16BE(data, pos))
      if pos + blobLen - 1 >= data.len:
        return err(DeblobTxFrameTruncated)
      let vtx = ?deblobify(data.toOpenArray(pos, pos + blobLen - 1), VertexRef)
      pos += blobLen
      if vtx.vType != StoLeaf:
        return err(DeblobUnknown)
      res.stoLeaves[h] = StoLeafRef(vtx)

  ok res

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
