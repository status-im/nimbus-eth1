# Fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This is a PoC of how execution block headers in the Portal history network
# could be proven to be part of the canonical chain by means of a proof that
# exists out a chain of proofs.
#
# It is the equivalent of beacon_chain_block_proof.nim but after Capella fork
# making use of historical_summaries instead of the frozen historical_roots.
#
#
# The usage of this PoC can be seen in
# ./fluffy/tests/test_beacon_chain_block_proof_capella.nim
#
# TODO: Fit both beacon_chain_block_proof_bellatrix.nim and
# beacon_chain_block_proof_capella.nim better together and add fork selection
# on top of it.
#

{.push raises: [].}

import
  results,
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  beacon_chain/spec/eth2_ssz_serialization,
  beacon_chain/spec/presets,
  beacon_chain/spec/datatypes/capella,
  ../beacon_chain_block_proof_common

export beacon_chain_block_proof_common

type
  HistoricalSummariesProof* = array[13, Digest]

  BeaconChainBlockProof* = object
    # Total size (11 + 1 + 13) * 32 bytes + 4 bytes = 804 bytes
    beaconBlockProof*: BeaconBlockProof
    beaconBlockRoot*: Digest
    historicalSummariesProof*: HistoricalSummariesProof
    slot*: Slot

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
): Result[HistoricalSummariesProof, string] =
  # max list size * 1 is start point of leaves
  let gIndex = GeneralizedIndex(SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  var proof: HistoricalSummariesProof
  ?blockRoots.build_proof(gIndex, proof)

  ok(proof)

# Put all 3 proofs together to be able to verify that an EL block hash
# is part of historical_summaries and thus canonical.
func buildProof*(
    blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest],
    beaconBlock: capella.TrustedBeaconBlock | capella.BeaconBlock,
): Result[BeaconChainBlockProof, string] =
  let
    blockRootIndex = getBlockRootsIndex(beaconBlock)
    beaconBlockProof = ?beaconBlock.buildProof()
    historicalSummariesProof = ?blockRoots.buildProof(blockRootIndex)

  ok(
    BeaconChainBlockProof(
      beaconBlockProof: beaconBlockProof,
      beaconBlockRoot: hash_tree_root(beaconBlock),
      historicalSummariesProof: historicalSummariesProof,
      slot: beaconBlock.slot,
    )
  )

func verifyProof*(
    blockHeaderRoot: Digest,
    proof: HistoricalSummariesProof,
    historicalRoot: Digest,
    blockRootIndex: uint64,
): bool =
  let gIndex = GeneralizedIndex(SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  verify_merkle_multiproof(@[blockHeaderRoot], proof, @[gIndex], historicalRoot)

func verifyProof*(
    historical_summaries: HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT],
    proof: BeaconChainBlockProof,
    blockHash: Digest,
    cfg: RuntimeConfig,
): bool =
  let
    historicalRootsIndex = getHistoricalSummariesIndex(proof.slot, cfg)
    blockRootIndex = getBlockRootsIndex(proof.slot)

  blockHash.verifyProof(proof.beaconBlockProof, proof.beaconBlockRoot) and
    proof.beaconBlockRoot.verifyProof(
      proof.historicalSummariesProof,
      historical_summaries[historicalRootsIndex].block_summary_root,
      blockRootIndex,
    )
