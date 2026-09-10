# Nimbus
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, stew/bitops2, beacon_chain/spec/presets, beacon_chain/spec/forks

from beacon_chain/spec/datatypes/capella import ExecutionPayload
from beacon_chain/spec/datatypes/deneb import ExecutionPayload

const
  # Bellatrix up to and including Fulu hold the execution payload in the
  # BeaconBlockBody, so the block hash is proven straight from the payload.
  EXECUTION_BLOCK_HASH_GINDEX* = get_generalized_index(
    capella.BeaconBlock, "body", "execution_payload", "block_hash"
  )
  EXECUTION_BLOCK_HASH_GINDEX_DENEB* =
    get_generalized_index(deneb.BeaconBlock, "body", "execution_payload", "block_hash")

  # Gloas (ePBS) moved the execution payload out of the BeaconBlockBody and into
  # a separate ExecutionPayloadEnvelope revealed by the builder. All that is
  # left in the block is the `SignedExecutionPayloadBid`, and its `block_hash`
  # is merely a commitment to a payload that may never be revealed: it becomes
  # canonical only once a later block confirms it.
  #
  # That confirmation is the `parent_block_hash` of the bid in such a later
  # block: it is asserted to be equal to `state.latest_block_hash`, which only
  # ever takes the block hash of a payload that was actually revealed and
  # processed. Proving it therefore proves that the execution block was
  # confirmed, which proving `block_hash` does not.
  # https://github.com/ethereum/consensus-specs/blob/v1.7.0-beta.0/specs/gloas/beacon-chain.md#execution-payload-bid
  #
  # This is also what the light client protocol does, see
  # https://github.com/ethereum/consensus-specs/blob/v1.7.0-beta.0/specs/gloas/light-client/full-node.md#modified-block_to_light_client_header
  #
  # As a consequence, from Gloas onwards a proof for an execution block is built
  # from the beacon block that *follows* the one its payload was committed in.
  EXECUTION_PARENT_BLOCK_HASH_GINDEX_GLOAS* = get_generalized_index(
    gloas.BeaconBlock, "body", "signed_execution_payload_bid", "message",
    "parent_block_hash",
  )

static:
  doAssert EXECUTION_BLOCK_HASH_GINDEX == 3228.GeneralizedIndex
  doAssert EXECUTION_BLOCK_HASH_GINDEX_DENEB == 6444.GeneralizedIndex
  doAssert EXECUTION_PARENT_BLOCK_HASH_GINDEX_GLOAS == 25384.GeneralizedIndex
  # Heze blocks are proven with the Gloas gindex, so its layout must not differ
  doAssert EXECUTION_PARENT_BLOCK_HASH_GINDEX_GLOAS ==
    get_generalized_index(
      heze.BeaconBlock, "body", "signed_execution_payload_bid", "message",
      "parent_block_hash",
    )

type
  ExecutionBlockProof* = array[log2trunc(EXECUTION_BLOCK_HASH_GINDEX), Digest]
  ExecutionBlockProofDeneb* =
    array[log2trunc(EXECUTION_BLOCK_HASH_GINDEX_DENEB), Digest]
  ExecutionBlockProofGloas* =
    array[log2trunc(EXECUTION_PARENT_BLOCK_HASH_GINDEX_GLOAS), Digest]

func getBlockRootsIndex*(slot: Slot): uint64 =
  slot mod SLOTS_PER_HISTORICAL_ROOT

func getBlockRootsIndex*(beaconBlock: SomeForkyBeaconBlock): uint64 =
  getBlockRootsIndex(beaconBlock.slot)

# Builds proof to be able to verify that the EL block hash is part of the
# CL BeaconBlock for given root.
func buildProof*(
    beaconBlock:
      bellatrix.TrustedBeaconBlock | bellatrix.BeaconBlock | capella.TrustedBeaconBlock |
      capella.BeaconBlock
): Result[ExecutionBlockProof, string] =
  var proof: ExecutionBlockProof
  ?beaconBlock.build_proof(EXECUTION_BLOCK_HASH_GINDEX, proof)

  ok(proof)

func buildProof*(
    beaconBlock:
      deneb.TrustedBeaconBlock | deneb.BeaconBlock | electra.TrustedBeaconBlock |
      electra.BeaconBlock | fulu.TrustedBeaconBlock | fulu.BeaconBlock
): Result[ExecutionBlockProofDeneb, string] =
  var proof: ExecutionBlockProofDeneb
  ?beaconBlock.build_proof(EXECUTION_BLOCK_HASH_GINDEX_DENEB, proof)

  ok(proof)

# Builds proof to be able to verify that the EL block hash confirmed by this
# CL BeaconBlock, i.e. the block hash of its parent execution block, is part of
# the BeaconBlock for given root.
func buildProof*(
    beaconBlock:
      gloas.TrustedBeaconBlock | gloas.BeaconBlock | heze.TrustedBeaconBlock |
      heze.BeaconBlock
): Result[ExecutionBlockProofGloas, string] =
  var proof: ExecutionBlockProofGloas
  ?beaconBlock.build_proof(EXECUTION_PARENT_BLOCK_HASH_GINDEX_GLOAS, proof)

  ok(proof)

func verifyProof*(
    blockHash: Digest, proof: ExecutionBlockProof, blockRoot: Digest
): bool =
  verify_merkle_multiproof(
    @[blockHash], proof, @[EXECUTION_BLOCK_HASH_GINDEX], blockRoot
  )

func verifyProof*(
    blockHash: Digest, proof: ExecutionBlockProofDeneb, blockRoot: Digest
): bool =
  verify_merkle_multiproof(
    @[blockHash], proof, @[EXECUTION_BLOCK_HASH_GINDEX_DENEB], blockRoot
  )

func verifyProof*(
    blockHash: Digest, proof: ExecutionBlockProofGloas, blockRoot: Digest
): bool =
  verify_merkle_multiproof(
    @[blockHash], proof, @[EXECUTION_PARENT_BLOCK_HASH_GINDEX_GLOAS], blockRoot
  )
