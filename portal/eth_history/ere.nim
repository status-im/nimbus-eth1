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
from ../common/common_types import decodeSsz

export e2store.readRecord

# Implementation of ere file format as per spec:
# https://github.com/eth-clients/e2store-format-specs/blob/ca2523a6420d64336000f5607c0b59df1a08c83b/formats/ere.md

const
  E2CompressedHeader* = [byte 0x03, 0x00]
  E2CompressedBody* = [byte 0x04, 0x00]
  E2CompressedSlimReceipts* = [byte 0x0a, 0x00]
  E2TotalDifficulty* = [byte 0x06, 0x00]
  E2Proof* = [byte 0x0b, 0x00]
  E2AccumulatorRoot* = [byte 0x07, 0x00]
  E2DynamicBlockIndex* = [byte 0x67, 0x32]

  MaxEreSize* = 8192

type
  Indexes* = seq[int] # Absolute positions in file

  DynamicBlockIndex* = object
    startNumber*: uint64
    indexesList*: seq[Indexes] # sequence of indexes per block
    componentCount*: uint64
    noReceipts*: bool
    noProofs*: bool

  Era* = distinct uint64 # Period of 8192 blocks (not an exact time unit)

  EreGroup* = object
    blockIndex*: DynamicBlockIndex

# As stated, not really a time unit but nevertheless, need the borrows
ethTimeUnit Era

template lenu64(x: untyped): untyped =
  uint64(len(x))

proc findDynamicBlockIndexStartOffset(f: IoHandle): Result[int64, string] =
  ?f.setFilePos(-16, SeekPosition.SeekCurrent).mapErr(toString)

  let
    componentCount = ?f.readIndexCount()
    count = ?f.readIndexCount() # Now we're back at the end of the index
    bytes = count.int64 * 8 * componentCount + 32

  ok(-bytes)

proc appendIndex(
    f: IoHandle,
    startNumber: uint64,
    indexesList: openArray[Indexes],
    componentCount: uint64,
): Result[int64, string] =
  let
    len = indexesList.len() * componentCount.int * sizeof(int64) + 24
    pos = ?f.appendHeader(E2DynamicBlockIndex, len)

  ?f.append(startNumber.uint64.toBytesLE())

  for indexes in indexesList:
    for i in indexes:
      ?f.append(cast[uint64](i - pos).toBytesLE())

  ?f.append(componentCount.toBytesLE())
  ?f.append(indexesList.lenu64().toBytesLE())

  ok(pos)

proc appendRecord(f: IoHandle, index: DynamicBlockIndex): Result[int64, string] =
  f.appendIndex(index.startNumber, index.indexesList, index.componentCount)

proc readDynamicBlockIndex*(
    f: IoHandle, noProofs: bool
): Result[DynamicBlockIndex, string] =
  var
    buf: seq[byte]
    pos: int

  let
    startPos = ?f.getFilePos().mapErr(toString)
    fileSize = ?f.getFileSize().mapErr(toString)
    header = ?f.readRecord(buf)

  if header.typ != E2DynamicBlockIndex:
    return err("not an index")
  if buf.len < 16:
    return err("index entry too small")
  if buf.len mod 8 != 0:
    return err("index length invalid")

  let
    blockNumber = uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7))
    componentCount = uint64.fromBytesLE(buf.toOpenArray(buf.len - 16, buf.len - 8 - 1))
    countTest = uint64.fromBytesLE(buf.toOpenArray(buf.len - 8, buf.len - 1))
    count = (buf.len - 3 * 8) div 8 div componentCount.int

  if componentCount < 3 or componentCount > 5:
    return err("component-count should be in the range of 3 - 5")

  pos += 8 # at first indexes

  # technically not an error, but we'll throw this sanity check in here..
  if blockNumber > int32.high().uint64:
    return err("fishy block number")

  var indexesList = newSeq[Indexes](count)
  for i in 0 ..< count:
    var indexes = newSeqUninit[int](componentCount)
    for j in 0 ..< componentCount.int:
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

  pos += 8 # Skip component-count
  if uint64(count) != uint64.fromBytesLE(buf.toOpenArray(pos, pos + 7)):
    return err("invalid count")

  ok(
    DynamicBlockIndex(
      startNumber: blockNumber,
      indexesList: indexesList,
      componentCount: componentCount,
      noReceipts: false,
        # TODO: hardcoded for now, leaving no option for reading ere files without receipts
      noProofs: noProofs,
    )
  )

proc skipRecord*(f: IoHandle): Result[void, string] =
  let header = ?readHeader(f)
  if header.len > 0:
    ?f.setFilePos(header.len, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  ok()

func startNumber*(era: Era): uint64 =
  era * MaxEreSize

func endNumber*(era: Era): uint64 =
  (era + 1) * MaxEreSize - 1'u64

func endNumber*(blockIdx: DynamicBlockIndex): uint64 =
  blockIdx.startNumber + blockIdx.indexesList.lenu64() - 1

func era*(blockNumber: uint64): Era =
  Era(blockNumber div MaxEreSize)

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

type Proof* = object
  proofType*: uint64
  proofData*: seq[byte]

proc init*(
    T: type EreGroup,
    f: IoHandle,
    startNumber: uint64,
    mergeBlockNumber: uint64,
    noReceipts = false,
    noProofs = false,
): Result[T, string] =
  discard ?f.appendHeader(E2Version, 0)

  let componentCount =
    2 + # header + body
    (if noReceipts: 0 else: 1) + (if noProofs: 0 else: 1) +
    (if era(startNumber) <= era(mergeBlockNumber): 1 else: 0) # td pre-merge + merge era

  # TODO: Not great ... Perhaps just make one big sequence and play with indexes.
  var indexesList = newSeq[Indexes](MaxEreSize)
  for i in 0 ..< MaxEreSize:
    indexesList[i] = newSeqUninit[int](componentCount)

  ok(
    EreGroup(
      blockIndex: DynamicBlockIndex(
        startNumber: startNumber,
        indexesList: indexesList,
        componentCount: componentCount.uint64,
        noReceipts: noReceipts,
        noProofs: noProofs,
      )
    )
  )

proc getIndexesPos(
    index: DynamicBlockIndex, headerType: array[2, byte]
): Result[int, string] =
  if headerType == E2CompressedHeader:
    ok(0)
  elif headerType == E2CompressedBody:
    ok(1)
  elif headerType == E2CompressedSlimReceipts:
    if index.noReceipts:
      err("Index doesn't have receipts")
    else:
      ok(2)
  elif headerType == E2Proof:
    if index.noProofs:
      err("Index doesn't have proofs")
    else:
      ok(2 + (if index.noReceipts: 0 else: 1))
  elif headerType == E2TotalDifficulty:
    if (2 + (if index.noReceipts: 0 else: 1) + (if index.noProofs: 0 else: 1) + 1) ==
        index.componentCount.int:
      ok(2 + (if index.noReceipts: 0 else: 1) + (if index.noProofs: 0 else: 1))
    else:
      err("Index doesn't have total difficulty")
  else:
    raiseAssert "Invalid header type"

proc update*(
    g: var EreGroup,
    f: IoHandle,
    blockNumber: uint64,
    data: openArray[byte],
    headerType: array[2, byte],
): Result[void, string] =
  doAssert blockNumber >= g.blockIndex.startNumber

  let
    index = int(blockNumber - g.blockIndex.startNumber)
    pos = ?getIndexesPos(g.blockIndex, headerType)

  if headerType == E2CompressedHeader:
    g.blockIndex.indexesList[index][pos] = ?f.appendRecord(E2CompressedHeader, data)
  elif headerType == E2CompressedBody:
    g.blockIndex.indexesList[index][pos] = ?f.appendRecord(E2CompressedBody, data)
  elif headerType == E2CompressedSlimReceipts:
    g.blockIndex.indexesList[index][pos] =
      ?f.appendRecord(E2CompressedSlimReceipts, data)
  elif headerType == E2Proof:
    g.blockIndex.indexesList[index][pos] = ?f.appendRecord(E2Proof, data)
  elif headerType == E2TotalDifficulty:
    g.blockIndex.indexesList[index][pos] = ?f.appendRecord(E2TotalDifficulty, data)
  else:
    return err("Invalid header type")

  ok()

proc update*(
    g: var EreGroup, f: IoHandle, blockNumber: uint64, header: headers.Header
): Result[void, string] =
  g.update(f, blockNumber, toCompressedRlpBytes(header), E2CompressedHeader)

proc update*(
    g: var EreGroup, f: IoHandle, blockNumber: uint64, body: BlockBody
): Result[void, string] =
  g.update(f, blockNumber, toCompressedRlpBytes(body), E2CompressedBody)

proc update*(
    g: var EreGroup, f: IoHandle, blockNumber: uint64, receipts: seq[StoredReceipt]
): Result[void, string] =
  # doAssert(not g.blockIndex.noReceipts)
  g.update(f, blockNumber, toCompressedRlpBytes(receipts), E2CompressedSlimReceipts)

proc update*(
    g: var EreGroup,
    f: IoHandle,
    blockNumber: uint64,
    proof:
      HistoricalHashesAccumulatorProof | BlockProofHistoricalRoots |
      BlockProofHistoricalSummaries | BlockProofHistoricalSummariesDeneb,
): Result[void, string] =
  let encodedProof =
    when proof is HistoricalHashesAccumulatorProof:
      toCompressedRlpBytes(Proof(proofType: 0x00, proofData: SSZ.encode(proof)))
    elif proof is BlockProofHistoricalRoots:
      toCompressedRlpBytes(Proof(proofType: 0x01, proofData: SSZ.encode(proof)))
    elif proof is BlockProofHistoricalSummaries:
      toCompressedRlpBytes(Proof(proofType: 0x02, proofData: SSZ.encode(proof)))
    elif proof is BlockProofHistoricalSummariesDeneb:
      toCompressedRlpBytes(Proof(proofType: 0x03, proofData: SSZ.encode(proof)))
    else:
      raiseAssert "Invalid proof type"
  g.update(f, blockNumber, encodedProof, E2Proof)

proc update*(
    g: var EreGroup, f: IoHandle, blockNumber: uint64, totalDifficulty: UInt256
): Result[void, string] =
  g.update(f, blockNumber, totalDifficulty.toBytesLE(), E2TotalDifficulty)

proc finish*(
    g: var EreGroup, f: IoHandle, accumulatorRoot: Opt[Digest], lastBlockNumber: uint64
): Result[void, string] =
  if accumulatorRoot.isSome():
    discard ?f.appendRecord(E2AccumulatorRoot, accumulatorRoot.value().data)

  if lastBlockNumber > 0:
    discard ?f.appendRecord(g.blockIndex)

  ok()

func shortLog*(x: Hash32): string =
  x.data.toOpenArray(0, 3).toHex()

func eraeFileName*(network: string, era: Era, eraRoot: Hash32): string =
  try:
    &"{network}-{era.uint64:05}-{shortLog(eraRoot)}.erae"
  except ValueError as exc:
    raiseAssert exc.msg

# Helpers to directly read objects from erae files
# TODO: Might want to var parameters to avoid copying as is done for era files.

type
  EreFile* = ref object
    handle: Opt[IoHandle]
    blockIdx*: DynamicBlockIndex
    mergeBlockNumber*: uint64

  # BlockTuple* =
  #   tuple[
  #     header: headers.Header,
  #     body: BlockBody,
  #     receipts: seq[StoredReceipt],
  #     proof: Proof,
  #     td: UInt256,
  #   ]

proc open*(
    _: type EreFile, name: string, mergeBlockNumber: uint64, noProofs: bool
): Result[EreFile, string] =
  var f = Opt[IoHandle].ok(?openFile(name, {OpenFlags.Read}).mapErr(ioErrorMsg))

  defer:
    if f.isSome():
      discard closeFile(f[])

  # Indices can be found at the end of each era file - we only support
  # single-era files for now
  ?f[].setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)

  # Last in the file is the block index
  let blockIdxPos = ?f[].findDynamicBlockIndexStartOffset()
  ?f[].setFilePos(blockIdxPos, SeekPosition.SeekCurrent).mapErr(ioErrorMsg)

  let blockIdx = ?f[].readDynamicBlockIndex(noProofs)
  if blockIdx.indexesList.len() != MaxEreSize:
    return err(
      "Block indexes list length invalid: " & $blockIdx.indexesList.len() &
        " vs expected " & $MaxEreSize
    )

  let res = EreFile(handle: f, blockIdx: blockIdx, mergeBlockNumber: mergeBlockNumber)
  reset(f)
  ok res

proc close*(f: EreFile) =
  if f.handle.isSome():
    discard closeFile(f.handle.get())
    reset(f.handle)

proc skipRecord*(f: EreFile): Result[void, string] =
  doAssert f[].handle.isSome()

  f[].handle.get().skipRecord()

proc getNextBlockHeader(f: EreFile, res: var headers.Header): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != E2CompressedHeader:
    return err("Invalid era file: didn't find block header at index position")

  fromCompressedRlpBytes(bytes, res)

proc getNextBlockBody(f: EreFile, res: var BlockBody): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != E2CompressedBody:
    return err("Invalid era file: didn't find block body at index position")

  fromCompressedRlpBytes(bytes, res)

proc getNextReceipts(f: EreFile, res: var seq[StoredReceipt]): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != E2CompressedSlimReceipts:
    return err("Invalid era file: didn't find receipts at index position")

  fromCompressedRlpBytes(bytes, res)

proc getNextProof(f: EreFile, res: var Proof): Result[void, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != E2Proof:
    return err("Invalid era file: didn't find proof at index position")

  fromCompressedRlpBytes(bytes, res)

proc getNextTotalDifficulty(f: EreFile): Result[UInt256, string] =
  var bytes: seq[byte]

  let header = ?f[].handle.get().readRecord(bytes)
  if header.typ != E2TotalDifficulty:
    return err("Invalid era file: didn't find total difficulty at index position")

  if bytes.len != 32:
    return err("Invalid total difficulty length")

  ok(UInt256.fromBytesLE(bytes))

proc getBlockHeader*(f: EreFile, blockNumber: uint64): Result[headers.Header, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let indexesPos = ?getIndexesPos(f.blockIdx, E2CompressedHeader)
  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][indexesPos]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  var res: headers.Header
  ?getNextBlockHeader(f, res)
  ok(move(res))

proc getBlockBody*(f: EreFile, blockNumber: uint64): Result[BlockBody, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let indexesPos = ?getIndexesPos(f.blockIdx, E2CompressedBody)
  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][indexesPos]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  var res: BlockBody
  ?getNextBlockBody(f, res)
  ok(move(res))

proc getReceipts*(f: EreFile, blockNumber: uint64): Result[seq[StoredReceipt], string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let indexesPos = ?getIndexesPos(f.blockIdx, E2CompressedSlimReceipts)
  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][indexesPos]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  var res: seq[StoredReceipt]
  ?getNextReceipts(f, res)
  ok(move(res))

proc getProof*(f: EreFile, blockNumber: uint64): Result[Proof, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let indexesPos = ?getIndexesPos(f.blockIdx, E2Proof)
  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][indexesPos]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  var res: Proof
  ?getNextProof(f, res)
  ok(move(res))

proc getTotalDifficulty*(f: EreFile, blockNumber: uint64): Result[UInt256, string] =
  doAssert not isNil(f) and f[].handle.isSome
  doAssert(
    blockNumber >= f[].blockIdx.startNumber and blockNumber <= f[].blockIdx.endNumber,
    "Wrong era1 file for selected block number",
  )

  let indexesPos = ?getIndexesPos(f.blockIdx, E2TotalDifficulty)
  let pos = f[].blockIdx.indexesList[blockNumber - f[].blockIdx.startNumber][indexesPos]

  ?f[].handle.get().setFilePos(pos, SeekPosition.SeekBegin).mapErr(ioErrorMsg)

  getNextTotalDifficulty(f)

proc getEthBlock*(f: EreFile, blockNumber: uint64): Result[Block, string] =
  var res: Block
  # var body: BlockBody
  res.header = ?getBlockHeader(f, blockNumber)
  var body = ?getBlockBody(f, blockNumber)

  res.transactions = move(body.transactions)
  res.uncles = move(body.uncles)
  res.withdrawals = move(body.withdrawals)

  ok(move(res))

# proc getBlockTuple*(
#     f: EreFile, blockNumber: uint64, res: var BlockTuple
# ): Result[void, string] =
#   ?getBlockHeader(f, res.header)
#   ?getBlockBody(f, res.body)
#   ?getReceipts(f, res.receipts)
#   ?getProof(f, res.proof)
#   res.td = ?getTotalDifficulty(f)

#   ok()

proc getAccumulatorRoot*(f: EreFile): Result[Digest, string] =
  ## Only for pre merge eras and actual merge era
  # Get position of DynamicBlockIndex
  ?f[].handle.get().setFilePos(0, SeekPosition.SeekEnd).mapErr(ioErrorMsg)
  let blockIdxPos = ?f[].handle.get().findDynamicBlockIndexStartOffset()

  # Accumulator root is 40 bytes before the DynamicBlockIndex
  let accumulatorRootPos = blockIdxPos - 40 # 8 + 32
  ?f[].handle.get().setFilePos(accumulatorRootPos, SeekPosition.SeekCurrent).mapErr(
    ioErrorMsg
  )

  var bytes: seq[byte]
  let header = ?f[].handle.get().readRecord(bytes)

  if header.typ != E2AccumulatorRoot:
    return err("Didn't find accumulator root at index position")

  if bytes.len != 32:
    return err("invalid accumulator root")

  ok(Digest(data: array[32, byte].initCopyFrom(bytes)))

proc buildAccumulator*(f: EreFile): Result[EpochRecordCached, string] =
  ## Only for pre merge eras and actual merge era.
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var headerRecords: seq[HeaderRecord]
  for blockNumber in startNumber .. endNumber:
    let header = ?f.getBlockHeader(blockNumber)
    let totalDifficulty = ?f.getTotalDifficulty(blockNumber)

    headerRecords.add(
      HeaderRecord(blockHash: header.computeRlpHash(), totalDifficulty: totalDifficulty)
    )

  ok(EpochRecordCached.init(headerRecords))

type HeaderVerifier* = object
  historicalHashes*: FinishedHistoricalHashesAccumulator
  historicalRoots*: HistoricalRoots
  historicalSummaries*: HistoricalSummaries

proc verifyProof*(
    proof: Proof, header: headers.Header, v: HeaderVerifier, cfg: RuntimeConfig
): Result[void, string] =
  if proof.proofType == 0x00:
    let decodedProof = decodeSsz(proof.proofData, HistoricalHashesAccumulatorProof).valueOr:
      return err("Invalid HistoricalHashesAccumulatorProof: $error")
    if not v.historicalHashes.verifyProof(header, decodedProof):
      return err("Invalid HistoricalHashesAccumulatorProof: verification failed")
  elif proof.proofType == 0x01:
    let decodedProof = decodeSsz(proof.proofData, BlockProofHistoricalRoots).valueOr:
      return err("Invalid BlockProofHistoricalRoots: $error")
    if not v.historicalRoots.verifyProof(
      decodedProof, Digest(data: header.computeRlpHash().data)
    ):
      return err("Invalid BlockProofHistoricalRoots: verification failed")
  elif proof.proofType == 0x02:
    let decodedProof = decodeSsz(proof.proofData, BlockProofHistoricalSummaries).valueOr:
      return err("Invalid BlockProofHistoricalSummaries: $error")
    if not v.historicalSummaries.verifyProof(
      decodedProof, Digest(data: header.computeRlpHash().data), cfg
    ):
      return err("Invalid BlockProofHistoricalSummaries: verification failed")
  elif proof.proofType == 0x03:
    let decodedProof = decodeSsz(proof.proofData, BlockProofHistoricalSummariesDeneb).valueOr:
      return err("Invalid BlockProofHistoricalSummariesDeneb: $error")
    if not v.historicalSummaries.verifyProof(
      decodedProof, Digest(data: header.computeRlpHash().data), cfg
    ):
      return err("Invalid BlockProofHistoricalSummariesDeneb: verification failed")
  else:
    return err("Invalid proof type")

  ok()

proc verify*(
    f: EreFile, v: HeaderVerifier, cfg: RuntimeConfig
): Result[Opt[Digest], string] =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  var
    header: headers.Header
    body: BlockBody
    receipts: seq[StoredReceipt]
    proof: Proof
    td: UInt256
    headerRecords: seq[HeaderRecord]
  for blockNumber in startNumber .. endNumber:
    let header = ?getBlockHeader(f, blockNumber)
    let body = ?getBlockBody(f, blockNumber)
    # Note: currently not allowing for failure on receipts
    let receipts = ?getReceipts(f, blockNumber)

    let
      txRoot = calcTxRoot(body.transactions)
      ommershHash = computeRlpHash(body.uncles)

    if header.txRoot != txRoot:
      return err("Invalid transactions root")

    if header.ommersHash != ommershHash:
      return err("Invalid ommers hash")

    if header.receiptsRoot != calcReceiptsRoot(receipts):
      return err("Invalid receipts root")

    if not f.blockIdx.noProofs:
      let proof = ?getProof(f, blockNumber)
      ?verifyProof(proof, header, v, cfg)

    if blockNumber < f.mergeBlockNumber:
      let td = ?getTotalDifficulty(f, blockNumber)

      headerRecords.add(
        HeaderRecord(blockHash: header.computeRlpHash(), totalDifficulty: td)
      )

  if era(startNumber) <= era(f.mergeBlockNumber):
    let expectedRoot = ?f.getAccumulatorRoot()
    let accumulatorRoot = getEpochRecordRoot(headerRecords)

    if accumulatorRoot != expectedRoot:
      return err("Invalid accumulator root")
    else:
      return ok(Opt.some(accumulatorRoot))

  ok(Opt.none(Digest))

iterator era1BlockHeaders*(f: EreFile): headers.Header =
  let
    startNumber = f.blockIdx.startNumber
    endNumber = f.blockIdx.endNumber()

  for blockNumber in startNumber .. endNumber:
    yield f.getBlockHeader(blockNumber).expect("Header can be read")

# iterator era1BlockTuples*(f: EreFile): BlockTuple =
#   let
#     startNumber = f.blockIdx.startNumber
#     endNumber = f.blockIdx.endNumber()

#   var blockTuple: BlockTuple
#   for blockNumber in startNumber .. endNumber:
#     f.getBlockTuple(blockNumber, blockTuple).expect("Block tuple can be read")
#     yield blockTuple
