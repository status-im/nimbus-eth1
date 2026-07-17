# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.
#
# Implementation of post-merge block proofs by making use of the historical_summaries
# accumulator.
# Types are defined here:
# https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#block-header
#
# Proof system explained here:
# https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#blockproofhistoricalsummaries
#
# The proof chain traverses from proving that the block hash is the one of the
# ExecutionPayload in the BeaconBlock to proving that this BeaconBlock is rooted
# in the historical_summaries.
#
# The historical_summaries accumulator is updated for every period since Capella.
# It can thus be used for block proofs for blocks after the Capella fork.
#
# Caveat:
# Roots in historical_summaries are only added every `SLOTS_PER_HISTORICAL_ROOT`
# slots. Recent blocks that are not part of a HistoricalSummary cannot be proven
# through this mechanism.
#
# Requirements:
#
# - For building the proofs:
# Portal node/bridge that has access to all the beacon chain data (blocks +
# specific state) for that specific period. This can be provided through era files.
#
# - For verifying the proofs:
# To verify the proof the historical_summaries field of the BeaconState is required.
# As the historical_summaries evolve over time, it is made available over the
# Portal beacon network for retrieval.
#
# Caveat:
# The historical_roots accumulator is frozen at the Capella fork, this means that
# it can only be used for the blocks before the Capella fork (= Bellatrix).
#

{.push raises: [].}

import
  results,
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  beacon_chain/spec/eth2_ssz_serialization,
  beacon_chain/spec/ssz_codec,
  beacon_chain/spec/datatypes/capella,
  beacon_chain/spec/forks,
  ./block_proof_common

export block_proof_common, ssz_codec

type
  BeaconBlockProofHistoricalSummaries* = array[13, Digest]

  BlockProofHistoricalSummaries* = object
    # Total size (13 + 1 + 11) * 32 bytes + 4 bytes = 804 bytes
    beaconBlockProof*: BeaconBlockProofHistoricalSummaries
    beaconBlockRoot*: Digest
    executionBlockProof*: ExecutionBlockProof
    slot*: Slot

  BlockProofHistoricalSummariesDeneb* = object
    # Total size (13 + 1 + 12) * 32 bytes + 4 bytes = 836 bytes
    beaconBlockProof*: BeaconBlockProofHistoricalSummaries
    beaconBlockRoot*: Digest
    executionBlockProof*: ExecutionBlockProofDeneb
    slot*: Slot

  HistoricalSummaries* = HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT]

template `[]`(x: openArray[Eth2Digest], chunk: Limit): Eth2Digest =
  # Nim 2.0 requires arrays to be indexed by the same type they're declared with.
  # Both HistoricalBatch.block_roots and HistoricalBatch.state_roots
  # are declared with uint64. But `Limit = int64`.
  # Looks like this template can be used as a workaround.
  # See https://github.com/status-im/nimbus-eth1/pull/2384
  x[chunk.uint64]

func getHistoricalSummariesIndex*(slot: Slot, cfg: RuntimeConfig): uint64 =
  (slot - cfg.CAPELLA_FORK_EPOCH * SLOTS_PER_EPOCH) div SLOTS_PER_HISTORICAL_ROOT

func getHistoricalSummariesIndex*(
    blockHeader: BeaconBlockHeader, cfg: RuntimeConfig
): uint64 =
  getHistoricalSummariesIndex(blockHeader.slot, cfg)

# Builds proof to be able to verify that a BeaconBlock root is part of the
# block_roots for given root.
func buildProof*(
    blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest], blockRootIndex: uint64
): Result[BeaconBlockProofHistoricalSummaries, string] =
  # max list size * 1 is start point of leaves
  let gIndex = GeneralizedIndex(SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  var proof: BeaconBlockProofHistoricalSummaries
  ?blockRoots.build_proof(gIndex, proof)

  ok(proof)

# Put all 3 proofs together to be able to verify that an EL block hash
# is part of historical_summaries and thus canonical.
func buildProof*(
    blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest],
    beaconBlock: capella.TrustedBeaconBlock | capella.BeaconBlock,
): Result[BlockProofHistoricalSummaries, string] =
  let
    blockRootIndex = getBlockRootsIndex(beaconBlock)
    executionBlockProof = ?beaconBlock.buildProof()
    beaconBlockProof = ?blockRoots.buildProof(blockRootIndex)

  ok(
    BlockProofHistoricalSummaries(
      beaconBlockRoot: hash_tree_root(beaconBlock),
      beaconBlockProof: beaconBlockProof,
      executionBlockProof: executionBlockProof,
      slot: beaconBlock.slot,
    )
  )

func buildProof*(
    blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest],
    beaconBlock:
      deneb.TrustedBeaconBlock | deneb.BeaconBlock | electra.TrustedBeaconBlock |
      electra.BeaconBlock,
): Result[BlockProofHistoricalSummariesDeneb, string] =
  let
    blockRootIndex = getBlockRootsIndex(beaconBlock)
    executionBlockProof = ?beaconBlock.buildProof()
    beaconBlockProof = ?blockRoots.buildProof(blockRootIndex)

  ok(
    BlockProofHistoricalSummariesDeneb(
      beaconBlockRoot: hash_tree_root(beaconBlock),
      beaconBlockProof: beaconBlockProof,
      executionBlockProof: executionBlockProof,
      slot: beaconBlock.slot,
    )
  )

func verifyProof*(
    blockHeaderRoot: Digest,
    proof: BeaconBlockProofHistoricalSummaries,
    historicalRoot: Digest,
    blockRootIndex: uint64,
): bool =
  let gIndex = GeneralizedIndex(SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  verify_merkle_multiproof(@[blockHeaderRoot], proof, @[gIndex], historicalRoot)

func verifyProof*(
    historical_summaries: HistoricalSummaries,
    proof: BlockProofHistoricalSummaries | BlockProofHistoricalSummariesDeneb,
    blockHash: Digest,
    cfg: RuntimeConfig,
): bool =
  let
    historicalRootsIndex = getHistoricalSummariesIndex(proof.slot, cfg)
    blockRootIndex = getBlockRootsIndex(proof.slot)

  if historical_summaries.len().uint64 <= historicalRootsIndex:
    return false

  blockHash.verifyProof(proof.executionBlockProof, proof.beaconBlockRoot) and
    proof.beaconBlockRoot.verifyProof(
      proof.beaconBlockProof,
      historical_summaries[historicalRootsIndex].block_summary_root,
      blockRootIndex,
    )
