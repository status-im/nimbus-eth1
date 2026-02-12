# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, typetraits],
  results,
  stew/[endians2, io2, byteutils, arrayops],
  stint,
  snappy,
  eth/common/[headers_rlp, blocks_rlp, receipts_rlp],
  beacon_chain/spec/beacon_time,
  ssz_serialization,
  ncli/e2store,
  ./block_proofs/historical_hashes_accumulator,
  ./block_proofs/block_proof_historical_hashes_accumulator,
  ./block_proofs/block_proof_historical_roots,
  ./block_proofs/block_proof_historical_summaries

from eth/common/eth_types_rlp import computeRlpHash
from nimcrypto/hash import fromHex
from ../../execution_chain/utils/utils import calcTxRoot, calcReceiptsRoot

export e2store.readRecord

# Implementation of erae file format as current described in:
# https://github.com/eth-clients/e2store-format-specs/pull/16

# The format can be summarized with the following expression:

# eraE := Version | CompressedHeader+ | CompressedBody+ | CompressedReceipts+ | Proofs+ | TotalDifficulty* | other-entries* | Accumulator? | BlockIndex

# Each basic element is its own e2store entry:

# Version            = { type: 0x6532, data: nil }
# CompressedHeader   = { type: 0x03,   data: snappyFramed(rlp(header)) }
# CompressedBody     = { type: 0x04,   data: snappyFramed(rlp(body)) }
# CompressedSlimReceipts = { type: 0x0a,   data: snappyFramed(rlp([tx-type, post-state-or-status, cumulative-gas, logs])) }
# TotalDifficulty    = { type: 0x06,   data: uint256(header.total_difficulty) }
# Proof              = { type: 0x0b    data: snappyFramed(rlp([proof-type, ssz(BlockProofHistoricalHashesAccumulator) | ssz(BlockProofHistoricalRoots) | ssz(BlockProofHistoricalSummaries)]))}
# AccumulatorRoot    = { type: 0x07,   data: hash_tree_root(List(HeaderRecord, 8192)) }
# Index              = { type: 0x6732, data: index }

# TODO
# - Blocks vs slots: Here just blocks. Will this be fine for easy proof verification?
# - name proof -> BlockProof?
# - Index naming currently is not great

const
  CompressedHeader* = [byte 0x03, 0x00]
  CompressedBody* = [byte 0x04, 0x00]
  CompressedSlimReceipts* = [byte 0x0a, 0x00]
  TotalDifficulty* = [byte 0x06, 0x00]
  Proof* = [byte 0x0b, 0x00]
  AccumulatorRoot* = [byte 0x07, 0x00]
  E2BlockIndex* = [byte 0x67, 0x32] # is this swapped around or not? ugh

  MaxEraESize* = 8192

type
  Indexes* = seq[int] # Absolute positions in file

  BlockIndex* = object
    startNumber*: uint64
    indexesList*: seq[Indexes] # sequence of indexes per block
    componentCount*: uint64
      # Number of components per block (e.g. header, body, receipts, td, proofs)

  EraE* = distinct uint64 # Period of 8192 blocks (not an exact time unit)

  EraEGroup* = object
    blockIndex*: BlockIndex

# As stated, not really a time unit but nevertheless, need the borrows
ethTimeUnit EraE

template lenu64(x: untyped): untyped =
  uint64(len(x))

proc appendIndex*(
    f: IoHandle,
    startNumber: uint64,
    indexesList: openArray[Indexes],
    componentCount: uint64,
): Result[int64, string] =
  let
    len = indexesList.len() * sizeof(int64) + 24
    pos = ?f.appendHeader(E2BlockIndex, len)

  ?f.append(startNumber.uint64.toBytesLE())

  for indexes in indexesList:
    for i in indexes:
      ?f.append(cast[uint64](i - pos).toBytesLE())

  ?f.append(componentCount.toBytesLE())
  ?f.append(indexesList.lenu64().toBytesLE())

  ok(pos)

proc appendRecord(f: IoHandle, index: BlockIndex): Result[int64, string] =
  f.appendIndex(index.startNumber, index.indexesList, index.componentCount)

proc readBlockIndex*(f: IoHandle): Result[BlockIndex, string] =
  var
    buf: seq[byte]
    pos: int

  let
    startPos = ?f.getFilePos().mapErr(toString)
    fileSize = ?f.getFileSize().mapErr(toString)
    header = ?f.readRecord(buf)

  if header.typ != E2BlockIndex:
    return err("not an index")
  if buf.len < 16:
    return err("index entry too small")
  if buf.len mod 8 != 0:
    return err("index length invalid")

  let
    blockNumber = uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7))
    componentCount = 5
      # TODO: get this value by changing filepos with + buf.len - 8, then jumping back
    count = buf.len div 8 div componentCount - 3 # TODO: Or just read it out
  pos += 8

  # technically not an error, but we'll throw this sanity check in here..
  if blockNumber > int32.high().uint64:
    return err("fishy block number")

  var indexesList = newSeq[Indexes](count)
  for i in 0 ..< count:
    var indexes = newSeqUninit[int](componentCount)
    for j in 0 ..< componentCount:
      let
        offset = uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7))
        absolute =
          if offset == 0:
            0'i64
          else:
            # Wrapping math is actually convenient here
            cast[int64](cast[uint64](startPos) + offset)

      if absolute < 0 or absolute > fileSize:
        return err("invalid offset")
      indexes[j] = absolute
      pos += 8
    indexesList[i] = indexes

  if uint64(componentCount) != uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7)):
    return err("only supported component count of 5 for now")

  pos += 8
  if uint64(count) != uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7)):
    return err("invalid count")

  ok(
    BlockIndex(
      startNumber: blockNumber, indexesList: indexesList, componentCount: uint64(componentCount)
    )
  )

proc skipRecord*(f: IoHandle): Result[void, string] =
  let header = ?readHeader(f)
  if header.len > 0:
    ?f.setFilePos(header.len, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  ok()

func startNumber*(era: EraE): uint64 =
  era * MaxEraESize

func endNumber*(era: EraE): uint64 =
  (era + 1) * MaxEraESize - 1'u64

func endNumber*(blockIdx: BlockIndex): uint64 =
  blockIdx.startNumber + blockIdx.indexesList.lenu64() - 1

func era*(blockNumber: uint64): EraE =
  EraE(blockNumber div MaxEraESize)

# TODO: move to some era helpers file
proc toCompressedRlpBytes(item: auto): seq[byte] =
  snappy.encodeFramed(rlp.encode(item))

# TODO: move to some era helpers file
proc fromCompressedRlpBytes[T](bytes: openArray[byte], v: var T): Result[void, string] =
  try:
    v = rlp.decode(decodeFramed(bytes, checkIntegrity = false), T)
    ok()
  except RlpError as e:
    err("Invalid compressed RLP data for " & $T & ": " & e.msg)

type BlockProof* = object
  proofType*: uint64
  proofData*: seq[byte]

proc init*(T: type EraEGroup, f: IoHandle, startNumber: uint64): Result[T, string] =
  discard ?f.appendHeader(E2Version, 0)

  ok(
    EraEGroup(
      blockIndex: BlockIndex(
        startNumber: startNumber,
        indexesList: newSeq[Indexes](MaxEraESize),
        componentCount: 5,
          # TODO: We do always 5 or make it 3-5 also? Waste of space mostly for TD
      )
    )
  )

proc update*(
    g: var EraEGroup,
    f: IoHandle,
    blockNumber: uint64,
    header, body, receipts, proof, totalDifficulty: openArray[byte],
      # TODO could make the latter two an Opt.
): Result[void, string] =
  doAssert blockNumber >= g.blockIndex.startNumber

  # TODO: adjust for filling in Indexes
  # g.blockIndex.indexesList[int(blockNumber - g.blockIndex.startNumber)] =
  #   ?f.appendRecord(CompressedHeader, header)
  # discard ?f.appendRecord(CompressedBody, body)
  # discard ?f.appendRecord(CompressedSlimReceipts, receipts)
  # discard ?f.appendRecord(Proof, proof)
  # discard ?f.appendRecord(TotalDifficulty, totalDifficulty)

  ok()

proc update*(
    g: var EraEGroup,
    f: IoHandle,
    blockNumber: uint64,
    header: headers.Header,
    body: BlockBody,
    receipts: seq[Receipt],
    totalDifficulty: UInt256, # Opt?
    proof:
      HistoricalHashesAccumulatorProof | BlockProofHistoricalRoots |
      BlockProofHistoricalSummaries | BlockProofHistoricalSummariesDeneb, # Opt?
): Result[void, string] =
  g.update(
    f,
    blockNumber,
    toCompressedRlpBytes(header),
    toCompressedRlpBytes(body),
    toCompressedRlpBytes(receipts),
    case proof.type
    of HistoricalHashesAccumulatorProof:
      toCompressedRlpBytes(BlockProof(proofType: 0x00, proofData: SSZ.encode(proof)))
    of BlockProofHistoricalRoots:
      toCompressedRlpBytes(BlockProof(proofType: 0x01, proofData: SSZ.encode(proof)))
    of BlockProofHistoricalSummaries:
      toCompressedRlpBytes(BlockProof(proofType: 0x02, proofData: SSZ.encode(proof)))
    of BlockProofHistoricalSummariesDeneb:
      toCompressedRlpBytes(BlockProof(proofType: 0x03, proofData: SSZ.encode(proof))),
    totalDifficulty.toBytesLE(),
  )

proc finish*(
    g: var EraEGroup, f: IoHandle, accumulatorRoot: Opt[Digest], lastBlockNumber: uint64
): Result[void, string] =
  if accumulatorRoot.isSome():
    discard ?f.appendRecord(AccumulatorRoot, accumulatorRoot.value().data)

  if lastBlockNumber > 0:
    discard ?f.appendRecord(g.blockIndex)

  ok()

func shortLog*(x: Digest): string =
  x.data.toOpenArray(0, 3).toHex()

func eraEFileName*(network: string, era: EraE, eraRoot: Digest): string =
  try:
    &"{network}-{era.uint64:05}-{shortLog(eraRoot)}.erae"
  except ValueError as exc:
    raiseAssert exc.msg

# Helpers to directly read objects from erae files
# TODO: Might want to var parameters to avoid copying as is done for era files.

type
  EraEFile* = ref object
    handle: Opt[IoHandle]
    blockIdx*: BlockIndex

  BlockTuple* =
    tuple[
      header: headers.Header,
      body: BlockBody,
      receipts: seq[Receipt],
      proof: BlockProof,
      td: UInt256,
    ]

proc open*(_: type EraEFile, name: string): Result[EraEFile, string] =
  var f = Opt[IoHandle].ok(?openFile(name, {OpenFlags.Read}).mapErr(ioErrorMsg))

  defer:
    if f.isSome():
      discard closeFile(f[])

  # Indices can be found at the end of each era file - we only support
  # single-era files for now
  ?f[].setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)

  # Last in the file is the block index
  let blockIdxPos = ?f[].findIndexStartOffset()
  ?f[].setFilePos(blockIdxPos, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  let blockIdx = ?f[].readBlockIndex()
  if blockIdx.indexesList.len() != MaxEraESize:
    return err(
      "Block indexes list length invalid: " & $blockIdx.indexesList.len() &
        " vs expected " & $MaxEraESize
    )

  let res = EraEFile(handle: f, blockIdx: blockIdx)
  reset(f)
  ok res

proc close*(f: EraEFile) =
  if f.handle.isSome():
    discard closeFile(f.handle.get())
    reset(f.handle)

proc skipRecord*(f: EraEFile): Result[void, string] =
  doAssert f[].handle.isSome()

  f[].handle.get().skipRecord()

proc getBlockHeader(f: EraEFile, res: var headers.Header): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != CompressedHeader:
    return err("Invalid era file: didn't find block header at index position")

  fromCompressedRlpBytes(bytes, res)

proc getBlockBody(f: EraEFile, res: var BlockBody): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != CompressedBody:
    return err("Invalid era file: didn't find block body at index position")

  fromCompressedRlpBytes(bytes, res)

proc getReceipts(f: EraEFile, res: var seq[Receipt]): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != CompressedSlimReceipts:
    return err("Invalid era file: didn't find receipts at index position")

  fromCompressedRlpBytes(bytes, res)

proc getProof(f: EraEFile, res: var BlockProof): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != Proof:
    return err("Invalid era file: didn't find proof at index position")

  fromCompressedRlpBytes(bytes, res)

proc getTotalDifficulty(f: EraEFile): Result[UInt256, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != TotalDifficulty:
    return err("Invalid era file: didn't find total difficulty at index position")

  if bytes.len != 32:
    return err("Invalid total difficulty length")

  ok(UInt256.fromBytesLE(bytes))

proc getNextEthBlock*(f: EraEFile, res: var Block): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome

  var body: BlockBody
  ?getBlockHeader(f, res.header)
  ?getBlockBody(f, body)

  ?skipRecord(f) # receipts
  ?skipRecord(f) # proof # TODO: Optional so should not blindly skip
  ?skipRecord(f) # totalDifficulty # TODO: Optional so should not blindly skip

  res.transactions = move(body.transactions)
  res.uncles = move(body.uncles)
  res.withdrawals = move(body.withdrawals)

  ok()

proc getEthBlock*(
    f: EraEFile, blockNumber: uint64, res: var Block
): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][0] # TODO

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getNextEthBlock(f, res)

proc getNextBlockTuple*(f: EraEFile, res: var BlockTuple): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome

  ?getBlockHeader(f, res.header)
  ?getBlockBody(f, res.body)
  ?getReceipts(f, res.receipts)
  ?getProof(f, res.proof) # TODO: Optional so should check for error
  res.td = ?getTotalDifficulty(f) # TODO: Optional so should check for error

  ok()

proc getBlockTuple*(
    f: EraEFile, blockNumber: uint64, res: var BlockTuple
): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][0] # TODO

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getNextBlockTuple(f, res)

proc getBlockHeader*(
    f: EraEFile, blockNumber: uint64, res: var headers.Header
): Result[void, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][0] # TODO

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getBlockHeader(f, res)

proc getTotalDifficulty*(f: EraEFile, blockNumber: uint64): Result[UInt256, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][0] # TODO

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  ?skipRecord(f) # Header
  ?skipRecord(f) # BlockBody
  ?skipRecord(f) # Receipts
  ?skipRecord(f) # Proof: TODO: Optional, don't blindly skip, or just use the indexes.
  getTotalDifficulty(f)

# TODO: Should we add this perhaps in the EraEFile object and grab it in open()?
proc getAccumulatorRoot*(f: EraEFile): Result[Digest, string] =
  # Get position of BlockIndex
  ?f[].handle.get().setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)
  let blockIdxPos = ?f[].handle.get().findIndexStartOffset()

  # Accumulator root is 40 bytes before the BlockIndex
  let accumulatorRootPos = blockIdxPos - 40 # 8 + 32
  ?f[].handle.get().setFilePos(accumulatorRootPos, SeekPosition.SeekCurrent).mapErr(
    ioErrorMsg
  )

  var bytes: seq[byte]
  let header = ?f[].handle.get().readRecord(bytes)

  if header.typ != AccumulatorRoot:
    return err("Didn't find accumulator root at index position")

  if bytes.len != 32:
    return err("invalid accumulator root")

  ok(Digest(data: array[32, byte].initCopyFrom(bytes)))

proc buildAccumulator*(f: EraEFile): Result[EpochRecordCached, string] =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var headerRecords: seq[HeaderRecord]
  var header: headers.Header
  for blockNumber in startNumber .. endNumber:
    ?f.getBlockHeader(blockNumber, header)
    let totalDifficulty = ?f.getTotalDifficulty(blockNumber)

    headerRecords.add(
      HeaderRecord(blockHash: header.computeRlpHash(), totalDifficulty: totalDifficulty)
    )

  ok(EpochRecordCached.init(headerRecords))

proc verify*(f: EraEFile): Result[Digest, string] =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var headerRecords: seq[HeaderRecord]
  var blockTuple: BlockTuple
  for blockNumber in startNumber .. endNumber:
    ?f.getBlockTuple(blockNumber, blockTuple)
    let
      txRoot = calcTxRoot(blockTuple.body.transactions)
      ommershHash = computeRlpHash(blockTuple.body.uncles)

    if blockTuple.header.txRoot != txRoot:
      return err("Invalid transactions root")

    if blockTuple.header.ommersHash != ommershHash:
      return err("Invalid ommers hash")

    if blockTuple.header.receiptsRoot != calcReceiptsRoot(blockTuple.receipts):
      return err("Invalid receipts root")

    # TODO: verify every proof?

    headerRecords.add(
      HeaderRecord(
        blockHash: blockTuple.header.computeRlpHash(), totalDifficulty: blockTuple.td
      )
    )

  let expectedRoot = ?f.getAccumulatorRoot()
  let accumulatorRoot = getEpochRecordRoot(headerRecords)

  if accumulatorRoot != expectedRoot:
    err("Invalid accumulator root")
  else:
    ok(accumulatorRoot)

iterator era1BlockHeaders*(f: EraEFile): headers.Header =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var header: headers.Header
  for blockNumber in startNumber .. endNumber:
    f.getBlockHeader(blockNumber, header).expect("Header can be read")
    yield header

iterator era1BlockTuples*(f: EraEFile): BlockTuple =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var blockTuple: BlockTuple
  for blockNumber in startNumber .. endNumber:
    f.getBlockTuple(blockNumber, blockTuple).expect("Block tuple can be read")
    yield blockTuple
