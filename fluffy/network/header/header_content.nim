# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md

{.push raises: [Defect].}

import
  std/options,
  nimcrypto/[sha2, hash],
  ssz_serialization, ssz_serialization/merkleization,
  eth/common/eth_types,
  ../../common/common_types

export ssz_serialization, merkleization

const
  epochSize* = 8192 # blocks
  maxHistoricalEpochs = 131072 # 2^17

type
  # Header Gossip Content Keys
  # https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md#content-keys

  ContentType* = enum
    accumulatorSnapshot = 0x00
    epochAccumulator = 0x01
    newBlockHeader = 0x02

  AccumulatorSnapshotKey* = object
    accumulatorRootHash*: Bytes32

  EpochAccumulatorKey* = object
    epochAccumulatorRootHash*: Bytes32

  NewBlockHeaderKey* = object
    blockHash*: BlockHash
    blockNumber*: UInt256

  ContentKey* = object
    case contentType*: ContentType
    of accumulatorSnapshot:
      accumulatorSnapshotKey*: AccumulatorSnapshotKey
    of epochAccumulator:
      epochAccumulatorKey*: EpochAccumulatorKey
    of newBlockHeader:
      newBlockHeaderKey*: NewBlockHeaderKey

  # Header Accumulator
  # https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md#accumulator-snapshot

  HeaderRecord* = object
    blockHash*: BlockHash
    totalDifficulty*: UInt256

  EpochAccumulator* = List[HeaderRecord, epochSize]

  Accumulator* = object
    historicalEpochs*: List[Bytes32, maxHistoricalEpochs]
    currentEpoch*: EpochAccumulator

func encode*(contentKey: ContentKey): ByteList =
  ByteList.init(SSZ.encode(contentKey))

func decode*(contentKey: ByteList): Option[ContentKey] =
  try:
    some(SSZ.decode(contentKey.asSeq(), ContentKey))
  except SszError:
    return none[ContentKey]()

func toContentId*(contentKey: ByteList): ContentId =
  # TODO: Should we try to parse the content key here for invalid ones?
  # TODO: For the accumulators it would be nice if we could just directly
  # use the existing root hash from in the content key
  let idHash = sha2.sha_256.digest(contentKey.asSeq())
  readUintBE[256](idHash.data)

func toContentId*(contentKey: ContentKey): ContentId =
  toContentId(encode(contentKey))

func updateAccumulator*(a: var Accumulator, header: BlockHeader) =
  let lastTotalDifficulty =
    if a.currentEpoch.len() == 0:
      0.stuint(256)
    else:
      a.currentEpoch[^1].totalDifficulty

  if a.currentEpoch.len() == epochSize:
    let epochHash = hash_tree_root(a.currentEpoch)

    doAssert(a.historicalEpochs.add(epochHash.data))
    a.currentEpoch = EpochAccumulator.init(@[])

  let headerRecord =
    HeaderRecord(
      blockHash: header.blockHash(),
      totalDifficulty: lastTotalDifficulty + header.difficulty)

  let res = a.currentEpoch.add(headerRecord)
  doAssert(res, "Can't fail because of currentEpoch length check")
