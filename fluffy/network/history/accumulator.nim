# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/hashes,
  eth/common/eth_types,
  ssz_serialization, ssz_serialization/[proofs, merkleization],
  ../../common/common_types,
  ./history_content

export ssz_serialization, merkleization, proofs

# Header Accumulator
# Part from specification
# https://github.com/ethereum/portal-network-specs/blob/master/header-gossip-network.md#accumulator-snapshot
# However, applied for the history network instead of the header gossip network
# as per https://github.com/ethereum/portal-network-specs/issues/153

const
  epochSize* = 8192 # blocks
  maxHistoricalEpochs = 131072 # 2^17

type
  HeaderRecord* = object
    blockHash*: BlockHash
    totalDifficulty*: UInt256

  EpochAccumulator* = List[HeaderRecord, epochSize]

  Accumulator* = object
    historicalEpochs*: List[Bytes32, maxHistoricalEpochs]
    currentEpoch*: EpochAccumulator

  BlockHashResultType* = enum
    BHash, HEpoch, UnknownBlockNumber

  BlockHashResult* = object
    case kind*: BlockHashResultType
    of BHash:
      blockHash*: BlockHash
    of HEpoch:
      epochHash*: Bytes32
      epochIndex*: uint64
      blockRelativeIndex*: uint64
    of UnknownBlockNumber:
      discard

proc newEmptyAccumulator*(): Accumulator =
  return Accumulator(
    historicalEpochs:  List[Bytes32, maxHistoricalEpochs].init(@[]),
    currentEpoch: List[HeaderRecord, epochSize].init(@[])
  )

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

func hash*(a: Accumulator): hashes.Hash =
  # TODO: This is used for the CountTable but it will be expensive.
  hash(hash_tree_root(a).data)

func buildAccumulator*(headers: seq[BlockHeader]): Accumulator =
  var accumulator: Accumulator
  for header in headers:
    updateAccumulator(accumulator, header)

  accumulator

func buildAccumulatorData*(headers: seq[BlockHeader]):
    seq[(ContentKey, EpochAccumulator)] =
  var accumulator: Accumulator
  var epochAccumulators: seq[(ContentKey, EpochAccumulator)]
  for header in headers:
    updateAccumulator(accumulator, header)

    if accumulator.currentEpoch.len() == epochSize:
      let
        rootHash = accumulator.currentEpoch.hash_tree_root()
        key = ContentKey(
          contentType: epochAccumulator,
          epochAccumulatorKey: EpochAccumulatorKey(
            epochHash: rootHash))

      epochAccumulators.add((key, accumulator.currentEpoch))

  epochAccumulators

## Calls and helper calls for building header proofs and verifying headers
## against the Accumulator and the header proofs.

func inCurrentEpoch*(bn: uint64, a: Accumulator): bool =
  bn > uint64(a.historicalEpochs.len() * epochSize) - 1

func inCurrentEpoch*(header: BlockHeader, a: Accumulator): bool =
  let blockNumber = header.blockNumber.truncate(uint64)
  return inCurrentEpoch(blockNumber, a)

func getEpochIndex*(bn: uint64): uint64 =
  bn div epochSize

func getEpochIndex*(header: BlockHeader): uint64 =
  let blockNumber = header.blockNumber.truncate(uint64)
  ## Get the index for the historical epochs
  return getEpochIndex(blockNumber)

func getHeaderRecordIndex(bn: uint64, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  uint64(bn - epochIndex * epochSize)

func getHeaderRecordIndex*(header: BlockHeader, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  return getHeaderRecordIndex(header.blockNumber.truncate(uint64), epochIndex)

func verifyProof*(
    a: Accumulator, proof: openArray[Digest], header: BlockHeader): bool =
  let
    epochIndex = getEpochIndex(header)
    epochAccumulatorHash = Digest(data: a.historicalEpochs[epochIndex])

    leave = hash_tree_root(header.blockHash())
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    # TODO: Implement more generalized `get_generalized_index`
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  verify_merkle_multiproof(@[leave], proof, @[gIndex], epochAccumulatorHash)

proc verifyHeader*(
    accumulator: Accumulator, header: BlockHeader, proof: Option[seq[Digest]]):
    Result[void, string] =
  if header.inCurrentEpoch(accumulator):
    let blockNumber = header.blockNumber.truncate(uint64)
    let relIndex = blockNumber - uint64(accumulator.historicalEpochs.len()) * epochSize

    if relIndex > uint64(accumulator.currentEpoch.len() - 1):
      return err("Blocknumber ahead of accumulator")

    if accumulator.currentEpoch[relIndex].blockHash == header.blockHash():
      ok()
    else:
      err("Header not part of canonical chain")
  else:
    if proof.isSome():
      if accumulator.verifyProof(proof.get, header):
        ok()
      else:
        err("Proof verification failed")
    else:
      err("Need proof to verify header")

func getHeaderHashForBlockNumber*(a: Accumulator, bn: UInt256): BlockHashResult=
  let blockNumber = bn.truncate(uint64)
  if inCurrentEpoch(blockNumber, a):
    let relIndex = blockNumber - uint64(a.historicalEpochs.len()) * epochSize

    if relIndex > uint64(a.currentEpoch.len() - 1):
      return BlockHashResult(kind: UnknownBlockNumber)

    return BlockHashResult(kind: BHash, blockHash: a.currentEpoch[relIndex].blockHash)
  else:
    let epochIndex = getEpochIndex(blockNumber)
    return BlockHashResult(
      kind: HEpoch,
      epochHash: a.historicalEpochs[epochIndex],
      epochIndex: epochIndex,
      blockRelativeIndex: getHeaderRecordIndex(blockNumber, epochIndex)
    )
