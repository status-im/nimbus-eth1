# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/rlp,
  eth/common/eth_types_rlp,
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  ../../../common/common_types,
  ../history_content

export ssz_serialization, merkleization, proofs, eth_types_rlp

# HistoricalHashesAccumulator, as per specification:
# https://github.com/ethereum/portal-network-specs/blob/master/history/history-network.md#the-historical-hashes-accumulator

const
  EPOCH_SIZE* = 8192 # block roots per epoch record
  MAX_HISTORICAL_EPOCHS = 2048'u64 # Should be sufficient for all networks as for
  # mainnet this is not even reached: ceil(mergeBlockNumber / EPOCH_SIZE) = 1897

  # Allow this to be adjusted at compile time for testing. If more constants
  # need to be adjusted we can add some presets file.
  mergeBlockNumber* {.intdefine.}: uint64 = 15537394

  # Note: This is like a ceil(mergeBlockNumber / EPOCH_SIZE)
  # Could use ceilDiv(mergeBlockNumber, EPOCH_SIZE) in future versions
  preMergeEpochs* = (mergeBlockNumber + EPOCH_SIZE - 1) div EPOCH_SIZE

  # TODO:
  # Currently disabled, because issue when testing with other
  # `mergeBlockNumber`, but it could be used as value to double check on at
  # merge block.
  # TODO: Could also be used as value to actual finish the accumulator, instead
  # of `mergeBlockNumber`, but:
  # - Still need to store the actual `mergeBlockNumber` and run-time somewhere
  # as it allows for each pre vs post merge block header checking.
  # - Should probably be stated in the portal network specs.
  # TERMINAL_TOTAL_DIFFICULTY = u256"58750000000000000000000"

type
  HeaderRecord* = object
    blockHash*: BlockHash
    totalDifficulty*: UInt256

  EpochRecord* = List[HeaderRecord, EPOCH_SIZE]

  # In the core code of Fluffy the `EpochRecord` type is solely used, as
  # `hash_tree_root` is done either once or never on this object after
  # serialization.
  # However for the generation of the proofs for all the headers in an epoch, it
  # needs to be run many times and the cached version of the SSZ list is
  # obviously much faster, so this second type is added for this usage.
  EpochRecordCached* = HashList[HeaderRecord, EPOCH_SIZE]

  HistoricalHashesAccumulator* = object
    historicalEpochs*: List[Bytes32, int(MAX_HISTORICAL_EPOCHS)]
    currentEpoch*: EpochRecord

  # HistoricalHashesAccumulator in its final state
  FinishedHistoricalHashesAccumulator* = object
    historicalEpochs*: List[Bytes32, int(MAX_HISTORICAL_EPOCHS)]
    currentEpoch*: EpochRecord

func init*(T: type HistoricalHashesAccumulator): T =
  HistoricalHashesAccumulator(
    historicalEpochs: List[Bytes32, int(MAX_HISTORICAL_EPOCHS)].init(@[]),
    currentEpoch: EpochRecord.init(@[]),
  )

func getEpochRecordRoot*(headerRecords: openArray[HeaderRecord]): Digest =
  let epochRecord = EpochRecord.init(@headerRecords)

  hash_tree_root(epochRecord)

func updateAccumulator*(a: var HistoricalHashesAccumulator, header: BlockHeader) =
  doAssert(
    header.number < mergeBlockNumber, "No post merge blocks for header accumulator"
  )

  let lastTotalDifficulty =
    if a.currentEpoch.len() == 0:
      0.stuint(256)
    else:
      a.currentEpoch[^1].totalDifficulty

  # TODO: It is a bit annoying to require an extra header + update call to
  # finish an epoch. However, if we were to move this after adding the
  # `HeaderRecord`, there would be no way to get the current total difficulty,
  # unless another field is introduced in the `HistoricalHashesAccumulator` object.
  if a.currentEpoch.len() == EPOCH_SIZE:
    let epochHash = hash_tree_root(a.currentEpoch)

    doAssert(a.historicalEpochs.add(epochHash.data))
    a.currentEpoch = EpochRecord.init(@[])

  let headerRecord = HeaderRecord(
    blockHash: header.blockHash(),
    totalDifficulty: lastTotalDifficulty + header.difficulty,
  )

  let res = a.currentEpoch.add(headerRecord)
  doAssert(res, "Can't fail because of currentEpoch length check")

func finishAccumulator*(
    a: var HistoricalHashesAccumulator
): FinishedHistoricalHashesAccumulator =
  # doAssert(a.currentEpoch[^2].totalDifficulty < TERMINAL_TOTAL_DIFFICULTY)
  # doAssert(a.currentEpoch[^1].totalDifficulty >= TERMINAL_TOTAL_DIFFICULTY)
  let epochHash = hash_tree_root(a.currentEpoch)

  doAssert(a.historicalEpochs.add(epochHash.data))

  FinishedHistoricalHashesAccumulator(historicalEpochs: a.historicalEpochs)

## Calls and helper calls for building header proofs and verifying headers
## against the HistoricalHashesAccumulator and the header proofs.

func getEpochIndex*(blockNumber: uint64): uint64 =
  blockNumber div EPOCH_SIZE

func getEpochIndex*(header: BlockHeader): uint64 =
  ## Get the index for the historical epochs
  getEpochIndex(header.number)

func getHeaderRecordIndex*(blockNumber: uint64, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  uint64(blockNumber - epochIndex * EPOCH_SIZE)

func getHeaderRecordIndex*(header: BlockHeader, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  getHeaderRecordIndex(header.number, epochIndex)

func isPreMerge*(blockNumber: uint64): bool =
  blockNumber < mergeBlockNumber

func isPreMerge*(header: BlockHeader): bool =
  isPreMerge(header.number)

func verifyProof(
    a: FinishedHistoricalHashesAccumulator,
    header: BlockHeader,
    proof: openArray[Digest],
): bool =
  let
    epochIndex = getEpochIndex(header)
    epochRecordHash = Digest(data: a.historicalEpochs[epochIndex])

    leave = hash_tree_root(header.blockHash())
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    gIndex = GeneralizedIndex(EPOCH_SIZE * 2 * 2 + (headerRecordIndex * 2))

  verify_merkle_multiproof(@[leave], proof, @[gIndex], epochRecordHash)

func verifyAccumulatorProof*(
    a: FinishedHistoricalHashesAccumulator,
    header: BlockHeader,
    proof: HistoricalHashesAccumulatorProof,
): Result[void, string] =
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
    a: FinishedHistoricalHashesAccumulator, header: BlockHeader, proof: BlockHeaderProof
): Result[void, string] =
  case proof.proofType
  of BlockHeaderProofType.historicalHashesAccumulatorProof:
    a.verifyAccumulatorProof(header, proof.historicalHashesAccumulatorProof)
  of BlockHeaderProofType.none:
    if header.isPreMerge():
      err("Pre merge header requires HistoricalHashesAccumulatorProof")
    else:
      # TODO:
      # Currently there is no proof solution for verifying headers post-merge.
      # Skipping canonical verification will allow for nodes to push block data
      # that is not part of the canonical chain.
      # For now we accept this flaw as the focus lies on testing data
      # availability up to the head of the chain.
      ok()

func buildProof*(
    header: BlockHeader, epochRecord: EpochRecord | EpochRecordCached
): Result[HistoricalHashesAccumulatorProof, string] =
  doAssert(header.isPreMerge(), "Must be pre merge header")

  let
    epochIndex = getEpochIndex(header)
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    gIndex = GeneralizedIndex(EPOCH_SIZE * 2 * 2 + (headerRecordIndex * 2))

  var proof: HistoricalHashesAccumulatorProof
  ?epochRecord.build_proof(gIndex, proof)

  ok(proof)

func buildHeaderWithProof*(
    header: BlockHeader, epochRecord: EpochRecord | EpochRecordCached
): Result[BlockHeaderWithProof, string] =
  let proof = ?buildProof(header, epochRecord)

  ok(
    BlockHeaderWithProof(
      header: ByteList[2048].init(rlp.encode(header)),
      proof: BlockHeaderProof.init(proof),
    )
  )
