# Nimbus
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
# TODO: Fit both beacon_chain_block_proof.nim and
# beacon_chain_block_proof_capella.nim better together and add fork selection
# on top of it.
#

{.push raises: [].}

import
  stew/results,
  ssz_serialization,
  ssz_serialization/[proofs, merkleization],
  beacon_chain/spec/eth2_ssz_serialization,
  beacon_chain/spec/presets,
  beacon_chain/spec/datatypes/capella

type
  BeaconBlockBodyProof* = array[8, Digest]
  BeaconBlockHeaderProof* = array[3, Digest]
  HistoricalSummariesProof* = array[13, Digest]

  BeaconChainBlockProof* = object
    # Total size (8 + 1 + 3 + 1 + 13) * 32 bytes + 4 bytes = 836 bytes
    beaconBlockBodyProof: BeaconBlockBodyProof
    beaconBlockBodyRoot: Digest
    beaconBlockHeaderProof: BeaconBlockHeaderProof
    beaconBlockHeaderRoot: Digest
    historicalSummariesProof: HistoricalSummariesProof
    slot: Slot

func getHistoricalRootsIndex*(slot: Slot, cfg: RuntimeConfig): uint64 =
  (slot - cfg.CAPELLA_FORK_EPOCH * SLOTS_PER_EPOCH) div SLOTS_PER_HISTORICAL_ROOT

func getHistoricalRootsIndex*(
    blockHeader: BeaconBlockHeader, cfg: RuntimeConfig
): uint64 =
  getHistoricalRootsIndex(blockHeader.slot, cfg)

func getBlockRootsIndex*(slot: Slot): uint64 =
  slot mod SLOTS_PER_HISTORICAL_ROOT

func getBlockRootsIndex*(blockHeader: BeaconBlockHeader): uint64 =
  getBlockRootsIndex(blockHeader.slot)

# Builds proof to be able to verify that the EL block hash is part of
# BeaconBlockBody for given root.
func buildProof*(
    blockBody: capella.BeaconBlockBody
): Result[BeaconBlockBodyProof, string] =
  # 16 as there are 10 fields
  # 9 as index (pos) of field = 9
  let gIndexTopLevel = (1 * 1 * 16 + 9)
  # 16 as there are 14 fields
  # 12 as pos of field = 12
  let gIndex = GeneralizedIndex(gIndexTopLevel * 1 * 16 + 12)

  var proof: BeaconBlockBodyProof
  ?blockBody.build_proof(gIndex, proof)

  ok(proof)

# Builds proof to be able to verify that the CL BlockBody root is part of
# BeaconBlockHeader for given root.
func buildProof*(
    blockHeader: BeaconBlockHeader
): Result[BeaconBlockHeaderProof, string] =
  # 5th field of container with 5 fields -> 7 + 5
  let gIndex = GeneralizedIndex(12)

  var proof: BeaconBlockHeaderProof
  ?blockHeader.build_proof(gIndex, proof)

  ok(proof)

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

# Put all 3 above proofs together to be able to verify that an EL block hash
# is part of historical_summaries and thus canonical.
func buildProof*(
    blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest],
    blockHeader: BeaconBlockHeader,
    blockBody: capella.BeaconBlockBody,
    cfg: RuntimeConfig,
): Result[BeaconChainBlockProof, string] =
  let
    blockRootIndex = getBlockRootsIndex(blockHeader)

    beaconBlockBodyProof = ?blockBody.buildProof()
    beaconBlockHeaderProof = ?blockHeader.buildProof()
    historicalSummariesProof = ?blockRoots.buildProof(blockRootIndex)

  ok(
    BeaconChainBlockProof(
      beaconBlockBodyProof: beaconBlockBodyProof,
      beaconBlockBodyRoot: hash_tree_root(blockBody),
      beaconBlockHeaderProof: beaconBlockHeaderProof,
      beaconBlockHeaderRoot: hash_tree_root(blockHeader),
      historicalSummariesProof: historicalSummariesProof,
      slot: blockHeader.slot,
    )
  )

func verifyProof*(
    blockHash: Digest, proof: BeaconBlockBodyProof, blockBodyRoot: Digest
): bool =
  let
    gIndexTopLevel = (1 * 1 * 16 + 9)
    gIndex = GeneralizedIndex(gIndexTopLevel * 1 * 16 + 12)

  verify_merkle_multiproof(@[blockHash], proof, @[gIndex], blockBodyRoot)

func verifyProof*(
    blockBodyRoot: Digest, proof: BeaconBlockHeaderProof, blockHeaderRoot: Digest
): bool =
  let gIndex = GeneralizedIndex(12)

  verify_merkle_multiproof(@[blockBodyRoot], proof, @[gIndex], blockHeaderRoot)

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
    historicalRootsIndex = getHistoricalRootsIndex(proof.slot, cfg)
    blockRootIndex = getBlockRootsIndex(proof.slot)

  blockHash.verifyProof(proof.beaconBlockBodyProof, proof.beaconBlockBodyRoot) and
    proof.beaconBlockBodyRoot.verifyProof(
      proof.beaconBlockHeaderProof, proof.beaconBlockHeaderRoot
    ) and
    proof.beaconBlockHeaderRoot.verifyProof(
      proof.historicalSummariesProof,
      historical_summaries[historicalRootsIndex].block_summary_root,
      blockRootIndex,
    )
