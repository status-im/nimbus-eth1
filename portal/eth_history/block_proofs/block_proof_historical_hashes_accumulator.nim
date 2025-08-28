# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/[headers_rlp],
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  ../../common/common_types,
  ../../network/legacy_history/history_content,
  ./historical_hashes_accumulator

export
  ssz_serialization, merkleization, proofs, common_types, historical_hashes_accumulator

#
# Implementation of pre-merge block proofs by making use of the frozen HistoricalHashesAccumulator
#
# Types are defined here:
# https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#block-header
#
# Proof system explained here:
# https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#blockproofhistoricalhashesaccumulator
#
# The HistoricalHashesAccumulator is frozen at TheMerge, this means that it can
# only be used for the blocks before TheMerge.
#
# Requirements:
#
# - For building the proofs:
# Portal node/bridge that has access to all the EL chain historical data (blocks)
# for that specific period. This can be provided through era1 files.
#
# - For verifying the proofs:
# To verify the proof the HistoricalHashesAccumulator is required.
# As this field is frozen, it can be baked into the client.
# Root of the HistoricalHashesAccumulator can be cross-verified with EIP-7643 data:
# https://github.com/ethereum/EIPs/blob/master/EIPS/eip-7643.md#pre-pos-root
#

# Total size: 15 * 32 bytes = 480 bytes
type HistoricalHashesAccumulatorProof* = array[15, Digest]

func getEpochIndex*(blockNumber: uint64): uint64 =
  blockNumber div EPOCH_SIZE

func getEpochIndex*(header: Header): uint64 =
  ## Get the index for the historical epochs
  getEpochIndex(header.number)

func getHeaderRecordIndex*(blockNumber: uint64, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  uint64(blockNumber - epochIndex * EPOCH_SIZE)

func getHeaderRecordIndex*(header: Header, epochIndex: uint64): uint64 =
  ## Get the relative header index for the epoch accumulator
  getHeaderRecordIndex(header.number, epochIndex)

func isPreMerge*(blockNumber: uint64): bool =
  blockNumber < mergeBlockNumber

func isPreMerge*(header: Header): bool =
  isPreMerge(header.number)

func verifyProof*(
    a: FinishedHistoricalHashesAccumulator,
    header: Header,
    proof: HistoricalHashesAccumulatorProof,
): bool =
  let
    epochIndex = getEpochIndex(header)
    epochRecordHash = Digest(data: a.historicalEpochs[epochIndex])

    leave = hash_tree_root(header.computeRlpHash())
    headerRecordIndex = getHeaderRecordIndex(header, epochIndex)

    # For lists, leaves starts at epochSize*2 (because of the extra len branch).
    # Then another *2 to enter one layer deeper in the `HeaderRecord`.
    #                 list_root
    #                 /       \
    #         list_data_root  len(list)
    #               / \
    #              /\ /\
    #             .......
    #            /  ... /\
    #       hr_root
    #        /    \
    # blockhash
    gIndex = GeneralizedIndex(EPOCH_SIZE * 2 * 2 + (headerRecordIndex * 2))

  verify_merkle_multiproof(@[leave], proof, @[gIndex], epochRecordHash)

func buildProof*(
    header: Header, epochRecord: EpochRecord | EpochRecordCached
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
    header: Header, epochRecord: EpochRecord | EpochRecordCached
): Result[BlockHeaderWithProof, string] =
  let proof = ?buildProof(header, epochRecord)

  ok(
    BlockHeaderWithProof(
      header: ByteList[MAX_HEADER_LENGTH].init(rlp.encode(header)),
      proof: ByteList[MAX_HEADER_PROOF_LENGTH].init(SSZ.encode(proof)),
    )
  )
