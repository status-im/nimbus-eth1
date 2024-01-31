# fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[strformat, typetraits],
  results, stew/[endians2, io2, byteutils],
  stint, snappy,
  eth/common/eth_types_rlp,
  beacon_chain/spec/beacon_time,
  ssz_serialization,
  ncli/e2store

from nimcrypto/hash import fromHex

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
# Accumulator        = { type: 0x07,   data: hash_tree_root(List(HeaderRecord, 8192)) }
# BlockIndex         = { type: 0x3266, data: block-index }

# TODO:
# Current unresolved issue:
# - Snappy does not give the same compression result as the implementation used
# by geth for some block headers and block bodies. This is an issue if we want
# to rely on sha256sum as checksum for the individual era1 files as is suggested
# in https://github.com/ethereum/go-ethereum/pull/26621
#
# Possible suggestions:
# - change the format to something like:
# era1 := Version | block-tuple* | other-entries* | Accumulator | BlockIndex? | BlockIndex(accumulator)
# or similar to have easy access to the accumulator root.
# - Name Accumulator type instead AccumulatorRoot
#

const
  # Note: When specification is more official, these could go with the other
  # E2S types.
  CompressedHeader*   = [byte 0x03, 0x00]
  CompressedBody*     = [byte 0x04, 0x00]
  CompressedReceipts* = [byte 0x05, 0x00]
  TotalDifficulty*    = [byte 0x06, 0x00]
  Accumulator*        = [byte 0x07, 0x00]
  E2BlockIndex*       = [byte 0x66, 0x32]

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

## Following types & procs are era1 specific

type
  Era1* = distinct uint64 # Period of 8192 blocks (not an exact time unit)

  Era1Group* = object
    blockIndex*: BlockIndex

# As stated, not really a time unit but nevertheless, need the borrows
ethTimeUnit Era1

# Note: appendIndex and appendRecord for BlockIndex are only different from
# its consensus layer counter parts because of usage of slot vs blockNumber.
# In practise, they do the same thing.
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

proc toCompressedRlpBytes(item: auto): seq[byte] =
  snappy.encodeFramed(rlp.encode(item))

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
  let
    accumulatorRootPos = ? f.appendRecord(Accumulator, accumulatorRoot.data)

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
