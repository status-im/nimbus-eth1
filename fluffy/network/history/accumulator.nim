# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  eth/rlp, eth/common/eth_types_rlp,
  ssz_serialization, ssz_serialization/[proofs, merkleization],
  ../../common/common_types,
  ./history_content

export ssz_serialization, merkleization, proofs, eth_types_rlp

# Header Accumulator, as per specification:
# https://github.com/ethereum/portal-network-specs/blob/master/history-network.md#the-header-accumulator
# But with the adjustment to finish the accumulator at merge point.

const
  epochSize* = 8192 # blocks
  # Allow this to be adjusted at compile time for testing. If more constants
  # need to be adjusted we can add some presets file.
  mergeBlockNumber* {.intdefine.}: uint64 = 15537394

  # Note: This is like a ceil(mergeBlockNumber / epochSize)
  # Could use ceilDiv(mergeBlockNumber, epochSize) in future versions
  preMergeEpochs* = (mergeBlockNumber + epochSize - 1) div epochSize

  # TODO:
  # Currently disabled, because issue when testing with other
  # `mergeBlockNumber`, but it could be used as value to double check on at
  # merge block.
  # TODO: Could also be used as value to actual finish the accumulator, instead
  # of `mergeBlockNumber`, but:
  # - Still need to store the actual `mergeBlockNumber` and run-time somewhere
  # as it allows for each pre vs post merge block header checking.
  # - Can't limit `historicalEpochs` SSZ list at `preMergeEpochs` value.
  # - Should probably be stated in the portal network specs.
  # TERMINAL_TOTAL_DIFFICULTY = u256"58750000000000000000000"

type
  HeaderRecord* = object
    blockHash*: BlockHash
    totalDifficulty*: UInt256

  EpochAccumulator* = List[HeaderRecord, epochSize]

  # In the core code of Fluffy the `EpochAccumulator` type is solely used, as
  # `hash_tree_root` is done either once or never on this object after
  # serialization.
  # However for the generation of the proofs for all the headers in an epoch, it
  # needs to be run many times and the cached version of the SSZ list is
  # obviously much faster, so this second type is added for this usage.
  EpochAccumulatorCached* = HashList[HeaderRecord, epochSize]

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

func finishAccumulator*(a: var Accumulator): FinishedAccumulator =
  # doAssert(a.currentEpoch[^2].totalDifficulty < TERMINAL_TOTAL_DIFFICULTY)
  # doAssert(a.currentEpoch[^1].totalDifficulty >= TERMINAL_TOTAL_DIFFICULTY)
  let epochHash = hash_tree_root(a.currentEpoch)

  doAssert(a.historicalEpochs.add(epochHash.data))

  FinishedAccumulator(historicalEpochs: a.historicalEpochs)

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

func verifyProof(
    a: FinishedAccumulator, header: BlockHeader, proof: openArray[Digest]): bool =
  let
    epochIndex = getEpochIndex(header)
    epochAccumulatorHash = Digest(data: a.historicalEpochs[epochIndex])

    leave = hash_tree_root(header.blockHash())
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    # TODO: Implement more generalized `get_generalized_index`
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  verify_merkle_multiproof(@[leave], proof, @[gIndex], epochAccumulatorHash)

func verifyAccumulatorProof*(
    a: FinishedAccumulator, header: BlockHeader, proof: AccumulatorProof):
    Result[void, string] =
  if header.isPreMerge():
    # Note: The proof is typed with correct depth, so no check on this is
    # required here.
    if a.verifyProof(header, proof):
      ok()
    else:
      err("Proof verification failed")
  else:
    err("Cannot verify post merge header with accumulator proof")

func verifyHeader*(
    a: FinishedAccumulator, header: BlockHeader, proof: BlockHeaderProof):
    Result[void, string] =
  case proof.proofType:
  of BlockHeaderProofType.accumulatorProof:
    a.verifyAccumulatorProof(header, proof.accumulatorProof)
  of BlockHeaderProofType.none:
    if header.isPreMerge():
      err("Pre merge header requires AccumulatorProof")
    else:
      # TODO:
      # Currently there is no proof solution for verifying headers post-merge.
      # Skipping canonical verification will allow for nodes to push block data
      # that is not part of the canonical chain.
      # For now we accept this flaw as the focus lies on testing data
      # availability up to the head of the chain.
      ok()

func buildProof*(
    header: BlockHeader,
    epochAccumulator: EpochAccumulator | EpochAccumulatorCached):
    Result[AccumulatorProof, string] =
  doAssert(header.isPreMerge(), "Must be pre merge header")

  let
    epochIndex = getEpochIndex(header)
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    # TODO: Implement more generalized `get_generalized_index`
    gIndex = GeneralizedIndex(epochSize*2*2 + (headerRecordIndex*2))

  var proof: AccumulatorProof
  ? epochAccumulator.build_proof(gIndex, proof)

  ok(proof)

func buildHeaderWithProof*(
    header: BlockHeader,
    epochAccumulator: EpochAccumulator | EpochAccumulatorCached):
    Result[BlockHeaderWithProof, string] =
  let proof = ? buildProof(header, epochAccumulator)

  ok(BlockHeaderWithProof(
    header: ByteList.init(rlp.encode(header)),
    proof: BlockHeaderProof.init(proof)))

func getBlockEpochDataForBlockNumber*(
    a: FinishedAccumulator, bn: UInt256): Result[BlockEpochData, string] =
  let blockNumber = bn.truncate(uint64)

  if blockNumber.isPreMerge:
    let epochIndex = getEpochIndex(blockNumber)

    ok(BlockEpochData(
      epochHash: a.historicalEpochs[epochIndex],
      blockRelativeIndex: getHeaderRecordIndex(blockNumber, epochIndex))
      )
  else:
    err("Block number is post merge: " & $blockNumber)
