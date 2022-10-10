# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/hashes,
  eth/common/eth_types_rlp,
  ssz_serialization, ssz_serialization/[proofs, merkleization],
  ../../common/common_types,
  ./history_content

export ssz_serialization, merkleization, proofs, eth_types_rlp

# Header Accumulator, as per specification:
# https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#the-header-accumulator
# But with the adjustment to finish the accumulator at merge point.

const
  epochSize* = 8192 # blocks
  # Allow this to be adjusted at compile time. If more constants need to be
  # adjusted we can add some presets file.
  mergeBlockNumber* {.intdefine.}: uint64 = 15537394

  # Note: This is like a ceil(mergeBlockNumber / epochSize)
  # Could use ceilDiv(mergeBlockNumber, epochSize) in future versions
  preMergeEpochs* = (mergeBlockNumber + epochSize - 1) div epochSize

type
  HeaderRecord* = object
    blockHash*: BlockHash
    totalDifficulty*: UInt256

  EpochAccumulator* = List[HeaderRecord, epochSize]

  Accumulator* = object
    historicalEpochs*: List[Bytes32, int(preMergeEpochs)]
    currentEpoch*: EpochAccumulator

  FinishedAccumulator* = object
    historicalEpochs*: List[Bytes32, int(preMergeEpochs)]

  BlockEpochData* = object
    epochHash*: Bytes32
    blockRelativeIndex*: uint64

func init*(T: type Accumulator): T =
  Accumulator(
    historicalEpochs: List[Bytes32, int(preMergeEpochs)].init(@[]),
    currentEpoch: EpochAccumulator.init(@[])
  )

# TODO:
# Could probably also make this work with TTD instead of merge block number.
func updateAccumulator*(
    a: var Accumulator, header: BlockHeader) =
  doAssert(header.blockNumber.truncate(uint64) < mergeBlockNumber,
    "No post merge blocks for header accumulator")

  let lastTotalDifficulty =
    if a.currentEpoch.len() == 0:
      0.stuint(256)
    else:
      a.currentEpoch[^1].totalDifficulty

  # TODO: It is a bit annoying to require an extra header + update call to
  # finish an epoch. However, if we were to move this after adding the
  # `HeaderRecord`, there would be no way to get the current total difficulty,
  # unless another field is introduced in the `Accumulator` object.
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

func isFinished*(a: Accumulator): bool =
  a.historicalEpochs.len() == (int)(preMergeEpochs)

func finishAccumulator*(a: var Accumulator) =
  let epochHash = hash_tree_root(a.currentEpoch)

  doAssert(a.historicalEpochs.add(epochHash.data))

func hash*(a: Accumulator): hashes.Hash =
  # TODO: This is used for the CountTable but it will be expensive.
  hash(hash_tree_root(a).data)

func buildAccumulator*(headers: seq[BlockHeader]): Accumulator =
  var accumulator: Accumulator
  for header in headers:
    updateAccumulator(accumulator, header)

    if header.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
      finishAccumulator(accumulator)

  accumulator

func buildAccumulatorData*(headers: seq[BlockHeader]):
    seq[(ContentKey, EpochAccumulator)] =
  var accumulator: Accumulator
  var epochAccumulators: seq[(ContentKey, EpochAccumulator)]
  for header in headers:
    updateAccumulator(accumulator, header)

    # TODO: By allowing updateAccumulator and finishAccumulator to return
    # optionally the finished epoch accumulators we would avoid double
    # hash_tree_root computations.
    if accumulator.currentEpoch.len() == epochSize:
      let
        rootHash = accumulator.currentEpoch.hash_tree_root()
        key = ContentKey(
          contentType: epochAccumulator,
          epochAccumulatorKey: EpochAccumulatorKey(
            epochHash: rootHash))

      epochAccumulators.add((key, accumulator.currentEpoch))

    if header.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
      let
        rootHash = accumulator.currentEpoch.hash_tree_root()
        key = ContentKey(
          contentType: epochAccumulator,
          epochAccumulatorKey: EpochAccumulatorKey(
            epochHash: rootHash))

      epochAccumulators.add((key, accumulator.currentEpoch))

      finishAccumulator(accumulator)

  epochAccumulators

## Calls and helper calls for building header proofs and verifying headers
## against the Accumulator and the header proofs.

func getEpochIndex*(blockNumber: uint64): uint64 =
  blockNumber div epochSize

func getEpochIndex*(header: BlockHeader): uint64 =
  let blockNumber = header.blockNumber.truncate(uint64)
  ## Get the index for the historical epochs
  getEpochIndex(blockNumber)

func getHeaderRecordIndex(blockNumber: uint64, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  uint64(blockNumber - epochIndex * epochSize)

func getHeaderRecordIndex*(header: BlockHeader, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  getHeaderRecordIndex(header.blockNumber.truncate(uint64), epochIndex)

func isPreMerge*(blockNumber: uint64): bool =
  blockNumber < mergeBlockNumber

func isPreMerge*(header: BlockHeader): bool =
  isPreMerge(header.blockNumber.truncate(uint64))

func verifyProof*(
    a: Accumulator, header: BlockHeader, proof: openArray[Digest]): bool =
  let
    epochIndex = getEpochIndex(header)
    epochAccumulatorHash = Digest(data: a.historicalEpochs[epochIndex])

    leave = hash_tree_root(header.blockHash())
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    # TODO: Implement more generalized `get_generalized_index`
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  verify_merkle_multiproof(@[leave], proof, @[gIndex], epochAccumulatorHash)

func verifyHeader*(
    a: Accumulator, header: BlockHeader, proof: openArray[Digest]):
    Result[void, string] =
  if header.isPreMerge():
    if a.verifyProof(header, proof):
      ok()
    else:
      err("Proof verification failed")
  else:
    err("Cannot verify post merge header with accumulator proof")

func getBlockEpochDataForBlockNumber*(
    a: Accumulator, bn: UInt256): Result[BlockEpochData, string] =
  let blockNumber = bn.truncate(uint64)

  if blockNumber.isPreMerge:
    let epochIndex = getEpochIndex(blockNumber)

    ok(BlockEpochData(
      epochHash: a.historicalEpochs[epochIndex],
      blockRelativeIndex: getHeaderRecordIndex(blockNumber, epochIndex))
      )
  else:
    err("Block number is post merge: " & $blockNumber)
