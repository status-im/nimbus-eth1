# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This is a PoC of how execution block headers in the Portal history network
# could be proven to be part of the canonical chain by means of a proof that
# exists out a chain of proofs.
#
# To verify this proof you need access to the BeaconState field
# historical_roots and the block hash of the execution block.
#
# The chain traverses from proving that the block hash is the one of the
# ExecutionPayload in the BeaconBlockBody, to proving that this BeaconBlockBody
# is the one that is rooted in the BeaconBlockHeader, to proving that this
# BeaconBlockHeader is rooted in the historical_roots.
#
# TODO: The middle proof is perhaps a bit silly as it doesn't win much space
# compared to just providing the BeaconHeader.
#
# Requirements:
#
# For building the proofs:
# - Node that has access to all the beacon chain data (state and blocks) and
# - it will be required to rebuild the HistoricalBatches.
#
# For verifying the proofs:
# - As mentioned, the historical_roots field of the state is required. This
# is currently in no way available over any of the consensus layer libp2p
# protocols. Thus a light client cannot really be build using these proofs,
# which makes it rather useless for now.
#
# Caveat:
#
# Roots in historical_roots are only added every `SLOTS_PER_HISTORICAL_ROOT`
# slots. Recent blocks that are not part of a historical_root cannot be proven
# through this mechanism. They need to be directly looked up in the block_roots
# BeaconState field.
#
# Alternative:
#
# This PoC is written with the idea of keeping execution BlockHeaders and
# BlockBodies available in the Portal history network in the same way post-merge
# as it is pre-merge. One could also simply decide to store the BeaconBlocks or
# BeaconBlockHeaders and BeaconBlockBodies directly. And get the execution
# payloads from there. This would require only 1 (or two, depending on what you
# store) of the proofs and might be more convenient if you want to / need to
# store the beacon data also on the network. It would require some rebuilding
# the structure of the Execution BlockHeader.
#
# Alternative ii:
#
# Verifying a specific block could also be done by making use of the
# LightClientUpdates. Picking the closest update, and walking back blocks from
# that block to the specific block. How much data is required to download would
# depend on the location of the block, but it could be quite significant.
# Of course, this again could be thrown in some accumulator, but that would
# then be required to be stored on the state to make it easy verifiable.
# A PoC of this process would be nice and it could be more useful for a system
# like the Nimbus verified proxy.
#
#
# The usage of this PoC can be seen in
# ./fluffy/tests/test_beacon_chain_block_proof.nim
#
# TODO: Probably needs to make usage of forks instead of just bellatrix.
#

{.used.}

{.push raises: [Defect].}

import
  stew/results,
  ssz_serialization, ssz_serialization/[proofs, merkleization],
  beacon_chain/spec/eth2_ssz_serialization,
  beacon_chain/spec/datatypes/bellatrix

type
  BeaconBlockBodyProof* = array[8, Digest]
  BeaconBlockHeaderProof* = array[3, Digest]
  HistoricalRootsProof* = array[14, Digest]

  BeaconChainBlockProof* = object
    # Total size (8 + 1 + 3 + 1 + 14) * 32 bytes + 4 bytes = 868 bytes
    beaconBlockBodyProof: BeaconBlockBodyProof
    beaconBlockBodyRoot: Digest
    beaconBlockHeaderProof: BeaconBlockHeaderProof
    beaconBlockHeaderRoot: Digest
    historicalRootsProof: HistoricalRootsProof
    slot: Slot

func getHistoricalRootsIndex*(slot: Slot): uint64 =
  slot div SLOTS_PER_HISTORICAL_ROOT

func getHistoricalRootsIndex*(blockHeader: BeaconBlockHeader): uint64 =
  getHistoricalRootsIndex(blockHeader.slot)

func getBlockRootsIndex*(
    slot: Slot, historicalRootIndex: uint64): uint64 =
  uint64(slot - historicalRootIndex * SLOTS_PER_HISTORICAL_ROOT)

func getBlockRootsIndex*(
    blockHeader: BeaconBlockHeader, historicalRootIndex: uint64): uint64 =
  getBlockRootsIndex(blockHeader.slot, historicalRootIndex)

func buildProof*(
    blockBody: bellatrix.BeaconBlockBody): Result[BeaconBlockBodyProof, string] =
  # 16 as there are 10 fields
  # 9 as index (pos) of field = 9
  let gIndexTopLevel = (1 * 1 * 16 + 9)
  # 16 as there are 14 fields
  # 12 as pos of field = 12
  let gIndex = GeneralizedIndex(gIndexTopLevel * 1 * 16 + 12)

  var proof: BeaconBlockBodyProof
  ? blockBody.build_proof(gIndex, proof)

  ok(proof)

func buildProof*(
    blockHeader: BeaconBlockHeader): Result[BeaconBlockHeaderProof, string] =
  # 5th field of container with 5 fields -> 7 + 5
  let gIndex = GeneralizedIndex(12)

  var proof: BeaconBlockHeaderProof
  ? blockHeader.build_proof(gIndex, proof)

  ok(proof)

func buildProof*(
    batch: HistoricalBatch, blockRootIndex: uint64):
    Result[HistoricalRootsProof, string] =
  # max list size * 2 is start point of leaves
  let gIndex = GeneralizedIndex(2 * SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  var proof: HistoricalRootsProof
  ? batch.build_proof(gIndex, proof)

  ok(proof)

func buildProof*(
    batch: HistoricalBatch,
    blockHeader: BeaconBlockHeader,
    blockBody: bellatrix.BeaconBlockBody):
    Result[BeaconChainBlockProof, string] =
  let
    historicalRootsIndex = getHistoricalRootsIndex(blockHeader)
    blockRootIndex = getBlockRootsIndex(blockHeader, historicalRootsIndex)

    beaconBlockBodyProof = ? blockBody.buildProof()
    beaconBlockHeaderProof = ? blockHeader.buildProof()
    historicalRootsProof = ? batch.buildProof(blockRootIndex)

  ok(BeaconChainBlockProof(
    beaconBlockBodyProof: beaconBlockBodyProof,
    beaconBlockBodyRoot: hash_tree_root(blockBody),
    beaconBlockHeaderProof: beaconBlockHeaderProof,
    beaconBlockHeaderRoot: hash_tree_root(blockHeader),
    historicalRootsProof: historicalRootsProof,
    slot: blockHeader.slot
  ))

func verifyProof*(
    blockHash: Digest,
    proof: BeaconBlockBodyProof,
    blockBodyRoot: Digest): bool =
  let
    gIndexTopLevel = (1 * 1 * 16 + 9)
    gIndex = GeneralizedIndex(gIndexTopLevel * 1 * 16 + 12)

  verify_merkle_multiproof(@[blockHash], proof, @[gIndex], blockBodyRoot)

func verifyProof*(
    blockBodyRoot: Digest,
    proof: BeaconBlockHeaderProof,
    blockHeaderRoot: Digest): bool =
  let gIndex = GeneralizedIndex(12)

  verify_merkle_multiproof(@[blockBodyRoot], proof, @[gIndex], blockHeaderRoot)

func verifyProof*(
    blockHeaderRoot: Digest,
    proof: HistoricalRootsProof,
    historicalRoot: Digest,
    blockRootIndex: uint64): bool =
  let gIndex = GeneralizedIndex(2 * SLOTS_PER_HISTORICAL_ROOT + blockRootIndex)

  verify_merkle_multiproof(@[blockHeaderRoot], proof, @[gIndex], historicalRoot)

func verifyProof*(
    historical_roots: HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT],
    proof: BeaconChainBlockProof,
    blockHash: Digest): bool =
  let
    historicalRootsIndex = getHistoricalRootsIndex(proof.slot)
    blockRootIndex = getBlockRootsIndex(proof.slot, historicalRootsIndex)

  blockHash.verifyProof(
      proof.beaconBlockBodyProof, proof.beaconBlockBodyRoot) and
    proof.beaconBlockBodyRoot.verifyProof(
      proof.beaconBlockHeaderProof, proof.beaconBlockHeaderRoot) and
    proof.beaconBlockHeaderRoot.verifyProof(
      proof.historicalRootsProof, historical_roots[historicalRootsIndex],
      blockRootIndex)
