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
  # TODO:
  # This proof only works up until Fulu fork.
  # For gloas+ the execution payload is no longer part of the BeaconBlockBody and thus
  # an additional proof type is required.
  EXECUTION_BLOCK_HASH_GINDEX* = get_generalized_index(
    capella.BeaconBlock, "body", "execution_payload", "block_hash"
  )
  EXECUTION_BLOCK_HASH_GINDEX_DENEB* =
    get_generalized_index(deneb.BeaconBlock, "body", "execution_payload", "block_hash")

static:
  doAssert EXECUTION_BLOCK_HASH_GINDEX == 3228.GeneralizedIndex
  doAssert EXECUTION_BLOCK_HASH_GINDEX_DENEB == 6444.GeneralizedIndex

type
  ExecutionBlockProof* = array[log2trunc(EXECUTION_BLOCK_HASH_GINDEX), Digest]
  ExecutionBlockProofDeneb* =
    array[log2trunc(EXECUTION_BLOCK_HASH_GINDEX_DENEB), Digest]

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
