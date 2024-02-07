# fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, typetraits],
  results, stew/[endians2, io2, byteutils, arrayops],
  stint, snappy,
  eth/common/eth_types_rlp,
  beacon_chain/spec/beacon_time,
  ssz_serialization,
  ncli/e2store,
  ../network/history/accumulator

from nimcrypto/hash import fromHex
from ../../nimbus/utils/utils import calcTxRoot, calcReceiptRoot

export e2store.readRecord

# Implementation of era1 file format as current described in:
# https://github.com/ethereum/go-ethereum/pull/26621

# era1 := Version | block-tuple* | other-entries* | Accumulator | BlockIndex
# block-tuple :=  CompressedHeader | CompressedBody | CompressedReceipts | TotalDifficulty

# block-index := starting-number | index | index | index ... | count

# CompressedHeader   = { type: 0x03,   data: snappyFramed(rlp(header)) }
# CompressedBody     = { type: 0x04,   data: snappyFramed(rlp(body)) }
# CompressedReceipts = { type: 0x05,   data: snappyFramed(rlp(receipts)) }
# TotalDifficulty    = { type: 0x06,   data: uint256(header.total_difficulty) }
# AccumulatorRoot    = { type: 0x07,   data: hash_tree_root(List(HeaderRecord, 8192)) }
# BlockIndex         = { type: 0x3266, data: block-index }

# Important note:
# Snappy does not give the same compression result as the implementation used
# by go-ethereum for some block headers and block bodies. This means that we
# cannot rely on the secondary verification mechanism that is based on doing the
# sha256sum of the full era1 files.
#

const
  # Note: When specification is more official, these could go with the other
  # E2S types.
  CompressedHeader*   = [byte 0x03, 0x00]
  CompressedBody*     = [byte 0x04, 0x00]
  CompressedReceipts* = [byte 0x05, 0x00]
  TotalDifficulty*    = [byte 0x06, 0x00]
  AccumulatorRoot*    = [byte 0x07, 0x00]
  E2BlockIndex*       = [byte 0x66, 0x32]

  MaxEra1Size* = 8192

type
  BlockIndex* = object
    startNumber*: uint64
    offsets*: seq[int64] # Absolute positions in file

template lenu64(x: untyped): untyped =
  uint64(len(x))

## Following procs are more e2s specific and copied from e2store.nim
## TODO: Split up e2store.nim between e2s and era1 specific parts and reuse
## e2s code.

proc toString(v: IoErrorCode): string =
  try: ioErrorMsg(v)
  except Exception as e: raiseAssert e.msg

proc append(f: IoHandle, data: openArray[byte]): Result[void, string] =
  if (? writeFile(f, data).mapErr(toString)) != data.len.uint:
    return err("could not write data")
  ok()

proc appendHeader(f: IoHandle, typ: Type, dataLen: int): Result[int64, string] =
  if dataLen.uint64 > uint32.high:
    return err("entry does not fit 32-bit length")

  let start = ? getFilePos(f).mapErr(toString)

  ? append(f, typ)
  ? append(f, toBytesLE(dataLen.uint32))
  ? append(f, [0'u8, 0'u8])

  ok(start)

proc checkBytesLeft(f: IoHandle, expected: int64): Result[void, string] =
  let size = ? getFileSize(f).mapErr(toString)
  if expected > size:
    return err("Record extends past end of file")

  let pos = ? getFilePos(f).mapErr(toString)
  if expected > size - pos:
    return err("Record extends past end of file")

  ok()

proc readFileExact(f: IoHandle, buf: var openArray[byte]): Result[void, string] =
  if (? f.readFile(buf).mapErr(toString)) != buf.len().uint:
    return err("missing data")
  ok()

proc readHeader(f: IoHandle): Result[Header, string] =
  var buf: array[10, byte]
  ? readFileExact(f, buf.toOpenArray(0, 7))

  var
    typ: Type
  discard typ.copyFrom(buf)

  # Conversion safe because we had only 4 bytes of length data
  let len = (uint32.fromBytesLE(buf.toOpenArray(2, 5))).int64

  # No point reading these..
  if len > int.high(): return err("header length exceeds int.high")

  # Must have at least that much data, or header is invalid
  ? f.checkBytesLeft(len)

  ok(Header(typ: typ, len: int(len)))

## Following types & procs are era1 specific

type
  Era1* = distinct uint64 # Period of 8192 blocks (not an exact time unit)

  Era1Group* = object
    blockIndex*: BlockIndex

# As stated, not really a time unit but nevertheless, need the borrows
ethTimeUnit Era1

# Note: appendIndex, appendRecord and readIndex for BlockIndex are only
# different from its consensus layer counter parts because of usage of slot vs
# blockNumber. In practise, they do the same thing.
proc appendIndex*(
    f: IoHandle, startNumber: uint64, offsets: openArray[int64]):
    Result[int64, string] =
  let
    len = offsets.len() * sizeof(int64) + 16
    pos = ? f.appendHeader(E2BlockIndex, len)

  ? f.append(startNumber.uint64.toBytesLE())

  for v in offsets:
    ? f.append(cast[uint64](v - pos).toBytesLE())

  ? f.append(offsets.lenu64().toBytesLE())

  ok(pos)

proc appendRecord(f: IoHandle, index: BlockIndex): Result[int64, string] =
  f.appendIndex(index.startNumber, index.offsets)

proc readBlockIndex*(f: IoHandle): Result[BlockIndex, string] =
  let
    startPos = ? f.getFilePos().mapErr(toString)
    fileSize = ? f.getFileSize().mapErr(toString)
    header = ? f.readHeader()

  if header.typ != E2BlockIndex: return err("not an index")
  if header.len < 16: return err("index entry too small")
  if header.len mod 8 != 0: return err("index length invalid")

  var buf: array[8, byte]
  ? f.readFileExact(buf)
  let
    blockNumber = uint64.fromBytesLE(buf)
    count = header.len div 8 - 2

  var offsets = newSeqUninitialized[int64](count)
  for i in 0..<count:
    ? f.readFileExact(buf)

    let
      offset = uint64.fromBytesLE(buf)
      absolute =
        if offset == 0: 0'i64
        else:
          # Wrapping math is actually convenient here
          cast[int64](cast[uint64](startPos) + offset)

    if absolute < 0 or absolute > fileSize: return err("Invalid offset")
    offsets[i] = absolute

  ? f.readFileExact(buf)
  if uint64(count) != uint64.fromBytesLE(buf): return err("invalid count")

  # technically not an error, but we'll throw this sanity check in here..
  if blockNumber > int32.high().uint64: return err("fishy block number")

  ok(BlockIndex(startNumber: blockNumber, offsets: offsets))

func startNumber*(era: Era1): uint64 =
  era * MaxEra1Size

func endNumber*(era: Era1): uint64 =
  if (era + 1) * MaxEra1Size - 1'u64 >= mergeBlockNumber:
    # The incomplete era just before the merge
    mergeBlockNumber - 1'u64
  else:
    (era + 1) * MaxEra1Size - 1'u64

func endNumber*(blockIdx: BlockIndex): uint64 =
  blockIdx.startNumber + blockIdx.offsets.lenu64() - 1

proc toCompressedRlpBytes(item: auto): seq[byte] =
  snappy.encodeFramed(rlp.encode(item))

proc fromCompressedRlpBytes(bytes: openArray[byte], T: type): Result[T, string] =
  try:
    ok(rlp.decode(decodeFramed(bytes, checkIntegrity = false), T))
  except RlpError as e:
    err("Invalid Compressed RLP data" & e.msg)

proc init*(
    T: type Era1Group, f: IoHandle, startNumber: uint64
  ): Result[T, string] =
  discard ? f.appendHeader(E2Version, 0)

  ok(Era1Group(
    blockIndex: BlockIndex(
      startNumber: startNumber,
      offsets: newSeq[int64](8192.int64)
  )))

proc update*(
    g: var Era1Group, f: IoHandle, blockNumber: uint64,
    header, body, receipts, totalDifficulty: openArray[byte]
  ): Result[void, string] =
  doAssert blockNumber >= g.blockIndex.startNumber

  g.blockIndex.offsets[int(blockNumber - g.blockIndex.startNumber)] =
    ? f.appendRecord(CompressedHeader, header)
  discard ? f.appendRecord(CompressedBody, body)
  discard ? f.appendRecord(CompressedReceipts, receipts)
  discard ? f.appendRecord(TotalDifficulty, totalDifficulty)

  ok()

proc update*(
    g: var Era1Group, f: IoHandle, blockNumber: uint64,
    header: BlockHeader, body: BlockBody, receipts: seq[Receipt],
    totalDifficulty: UInt256
  ): Result[void, string] =
  g.update(
    f, blockNumber,
    toCompressedRlpBytes(header),
    toCompressedRlpBytes(body),
    toCompressedRlpBytes(receipts),
    totalDifficulty.toBytesLE()
  )

proc finish*(
    g: var Era1Group, f: IoHandle, accumulatorRoot: Digest, lastBlockNumber: uint64
  ):Result[void, string] =
  let accumulatorRootPos = ? f.appendRecord(AccumulatorRoot, accumulatorRoot.data)

  if lastBlockNumber > 0:
    discard ? f.appendRecord(g.blockIndex)

  # TODO:
  # This is not something added in current specification of era1.
  # But perhaps we want to be able to quickly jump to acummulator root.
  # discard ? f.appendIndex(lastBlockNumber, [accumulatorRootPos])
  discard accumulatorRootPos

  ok()

func shortLog*(x: Digest): string =
  x.data.toOpenArray(0, 3).toHex()

func era1FileName*(network: string, era: Era1, eraRoot: Digest): string =
  try:
    &"{network}-{era.uint64:05}-{shortLog(eraRoot)}.era1"
  except ValueError as exc:
    raiseAssert exc.msg

# Helpers to directly read objects from era1 files
# TODO: Might want to var parameters to avoid copying as is done for era files.

type
  Era1File* = ref object
    handle: Opt[IoHandle]
    blockIdx: BlockIndex

proc open*(_: type Era1File, name: string): Result[Era1File, string] =
  var
    f = Opt[IoHandle].ok(? openFile(name, {OpenFlags.Read}).mapErr(ioErrorMsg))

  defer:
    if f.isSome(): discard closeFile(f[])

  # Indices can be found at the end of each era file - we only support
  # single-era files for now
  ? f[].setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)

  # Last in the file is the block index
  let
    blockIdxPos = ? f[].findIndexStartOffset()
  ? f[].setFilePos(blockIdxPos, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  let blockIdx = ? f[].readBlockIndex()
  # Note: Could do an additional offset.len check here by calculating what it
  # should be based on mergeBlockNumber. It is however not necessary as the
  # accumulator root will fail if to many blocks are added (it will take a bit
  # longer though).

  let res = Era1File(handle: f, blockIdx: blockIdx)
  reset(f)
  ok res

proc close*(f: Era1File) =
  if f.handle.isSome():
    discard closeFile(f.handle.get())
    reset(f.handle)

proc getBlockHeader(f: Era1File): Result[BlockHeader, string] =
  var bytes: seq[byte]

  let header = ? f[].handle.get().readRecord(bytes)
  if header.typ != CompressedHeader:
    return err("Invalid era file: didn't find block header at index position")

  fromCompressedRlpBytes(bytes, BlockHeader)

proc getBlockBody(f: Era1File): Result[BlockBody, string] =
  var bytes: seq[byte]

  let header = ? f[].handle.get().readRecord(bytes)
  if header.typ != CompressedBody:
    return err("Invalid era file: didn't find block body at index position")

  fromCompressedRlpBytes(bytes, BlockBody)

proc getReceipts(f: Era1File): Result[seq[Receipt], string] =
  var bytes: seq[byte]

  let header = ? f[].handle.get().readRecord(bytes)
  if header.typ != CompressedReceipts:
    return err("Invalid era file: didn't find receipts at index position")

  fromCompressedRlpBytes(bytes, seq[Receipt])

proc getTotalDifficulty(f: Era1File): Result[UInt256, string] =
  var bytes: seq[byte]

  let header = ? f[].handle.get().readRecord(bytes)
  if header.typ != TotalDifficulty:
    return err("Invalid era file: didn't find total difficulty at index position")

  if bytes.len != 32:
    return err("Invalid total difficulty length")

  ok(UInt256.fromBytesLE(bytes))

proc getNextBlockTuple*(
    f: Era1File
  ): Result[(BlockHeader, BlockBody, seq[Receipt], UInt256), string] =
  doAssert not isNil(f) and f[].handle.isSome

  let
    blockHeader = ? getBlockHeader(f)
    blockBody = ? getBlockBody(f)
    receipts = ? getReceipts(f)
    totalDifficulty = ? getTotalDifficulty(f)

  ok((blockHeader, blockBody, receipts, totalDifficulty))

proc getBlockTuple*(
    f: Era1File, blockNumber: uint64
  ): Result[(BlockHeader, BlockBody, seq[Receipt], UInt256), string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and
    blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number")

  let pos = f[].blockIdx.offsets[blockNumber - f[].blockIdx.startNumber]

  ? f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getNextBlockTuple(f)

# TODO: Should we add this perhaps in the Era1File object and grab it in open()?
proc getAccumulatorRoot*(f: Era1File): Result[Digest, string] =
  # Get position of BlockIndex
  ? f[].handle.get().setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)
  let blockIdxPos = ? f[].handle.get().findIndexStartOffset()

  # Accumulator root is 40 bytes before the BlockIndex
  let accumulatorRootPos = blockIdxPos - 40 # 8 + 32
  ? f[].handle.get().setFilePos(accumulatorRootPos, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  var bytes: seq[byte]
  let header = ? f[].handle.get().readRecord(bytes)

  if header.typ != AccumulatorRoot:
    return err("Invalid era file: didn't find accumulator root at index position")

  if bytes.len != 32:
    return err("invalid accumulator root")

  ok(Digest(data: array[32, byte].initCopyFrom(bytes)))

proc verify*(f: Era1File): Result[Digest, string] =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var headerRecords: seq[HeaderRecord]
  for blockNumber in startNumber..endNumber:
    let
      (blockHeader, blockBody, receipts, totalDifficulty) =
        ? f.getBlockTuple(blockNumber)

      txRoot = calcTxRoot(blockBody.transactions)
      ommershHash = keccakHash(rlp.encode(blockBody.uncles))

    if blockHeader.txRoot != txRoot:
      return err("Invalid transactions root")

    if blockHeader.ommersHash != ommershHash:
      return err("Invalid ommers hash")

    if blockHeader.receiptRoot != calcReceiptRoot(receipts):
      return err("Invalid receipts root")

    headerRecords.add(HeaderRecord(
      blockHash: blockHeader.blockHash(),
      totalDifficulty: totalDifficulty))

  let expectedRoot = ? f.getAccumulatorRoot()
  let accumulatorRoot = getEpochAccumulatorRoot(headerRecords)

  if accumulatorRoot != expectedRoot:
    err("Invalid accumulator root")
  else:
    ok(accumulatorRoot)
