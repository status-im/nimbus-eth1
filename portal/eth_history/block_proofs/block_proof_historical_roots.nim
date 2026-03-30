# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
#
# Implementation of post-merge block proofs by making use of the historical_roots
# accumulator.
# Types are defined here:
# https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#block-header
#
# Proof system explained here:
# https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#blockproofhistoricalroots
#
# The proof chain traverses from proving that the block hash is the one of the
# ExecutionPayload in the BeaconBlock to proving that this BeaconBlock is rooted
# in the historical_roots.
#
# The historical_roots accumulator is frozen at the Capella fork, this means that
# it can only be used for the blocks from TheMerge until the Capella fork (= Bellatrix).
#
# Requirements:
#
# - For building the proofs:
# Portal node/bridge that has access to all the beacon chain data (blocks +
# specific state) for that specific period. This can be provided through era files.
#
# - For verifying the proofs:
# To verify the proof the historical_roots field of the BeaconState is required.
# As this field is frozen, it can be baked into the client.
#

{.push raises: [].}

import
  results,
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  beacon_chain/spec/eth2_ssz_serialization,
  beacon_chain/spec/ssz_codec,
  beacon_chain/spec/datatypes/bellatrix,
  beacon_chain/spec/forks,
  ./block_proof_common

export block_proof_common, ssz_codec

type
  BeaconBlockProofHistoricalRoots* = array[14, Digest]

  BlockProofHistoricalRoots* = object
    # Total size (14 + 1 + 11) * 32 bytes + 4 bytes = 836 bytes
    beaconBlockProof*: BeaconBlockProofHistoricalRoots
    beaconBlockRoot*: Digest
    executionBlockProof*: ExecutionBlockProof
    slot*: Slot

  HistoricalRoots* = HashList[Digest, Limit HISTORICAL_ROOTS_LIMIT]

func getHistoricalRootsIndex*(slot: Slot): uint64 =
  slot div SLOTS_PER_HISTORICAL_ROOT

func getHistoricalRootsIndex*(blockHeader: BeaconBlockHeader): uint64 =
  getHistoricalRootsIndex(blockHeader.slot)

template `[]`(x: openArray[Eth2Digest], chunk: Limit): Eth2Digest =
  # Nim 2.0 requires arrays to be indexed by the same type they're declared with.
  # Both HistoricalBatch.block_roots and HistoricalBatch.state_roots
  # are declared with uint64. But `Limit = int64`.
  # Looks like this template can be used as a workaround.
  # See https://github.com/status-im/nimbus-eth1/pull/2384
  x[chunk.uint64]

# Builds proof to be able to verify that a BeaconBlock root is part of the
# HistoricalBatch for given root.
func buildProof*(
    batch: HistoricalBatch, blockRootIndex: uint64
): Result[BeaconBlockProofHistoricalRoots, string] =
  # max list size * 2 is start point of leaves
  let gIndex = GeneralizedIndex(2 * SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  var proof: BeaconBlockProofHistoricalRoots
  ?batch.build_proof(gIndex, proof)

  ok(proof)

func buildProof*(
    batch: HistoricalBatch,
    beaconBlock: bellatrix.TrustedBeaconBlock | bellatrix.BeaconBlock,
): Result[BlockProofHistoricalRoots, string] =
  let
    blockRootIndex = getBlockRootsIndex(beaconBlock)
    executionBlockProof = ?beaconBlock.buildProof()
    beaconBlockProof = ?batch.buildProof(blockRootIndex)

  ok(
    BlockProofHistoricalRoots(
      beaconBlockProof: beaconBlockProof,
      beaconBlockRoot: hash_tree_root(beaconBlock),
      executionBlockProof: executionBlockProof,
      slot: beaconBlock.slot,
    )
  )

func verifyProof*(
    blockHeaderRoot: Digest,
    proof: BeaconBlockProofHistoricalRoots,
    historicalRoot: Digest,
    blockRootIndex: uint64,
): bool =
  let gIndex = GeneralizedIndex(2 * SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  verify_merkle_multiproof(@[blockHeaderRoot], proof, @[gIndex], historicalRoot)

func verifyProof*(
    historical_roots: HistoricalRoots,
    proof: BlockProofHistoricalRoots,
    blockHash: Digest,
): bool =
  let
    historicalRootsIndex = getHistoricalRootsIndex(proof.slot)
    blockRootIndex = getBlockRootsIndex(proof.slot)

  blockHash.verifyProof(proof.executionBlockProof, proof.beaconBlockRoot) and
    proof.beaconBlockRoot.verifyProof(
      proof.beaconBlockProof, historical_roots[historicalRootsIndex], blockRootIndex
    )
