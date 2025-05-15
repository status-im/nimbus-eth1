# Fluffy
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, stew/bitops2, beacon_chain/spec/presets, beacon_chain/spec/forks

const
  # BeaconBlock level:
  # - 8 as there are 5 fields
  # - 4 as index (pos) of field is 4
  gIndexTopLevel = (1 * 1 * 8 + 4)
  # BeaconBlockBody level:
  # - 16 as there are 10 fields
  # - 9 as index (pos) of field is 9
  gIndexMidLevel = (gIndexTopLevel * 1 * 16 + 9)
  # ExecutionPayload level:
  # - 16 as there are 14 fields
  # - 12 as pos of field is 12
  EXECUTION_BLOCK_HASH_GINDEX* = GeneralizedIndex(gIndexMidLevel * 1 * 16 + 12)
  # ExecutionPayload Deneb level:
  # - 32 as there are 17 fields
  # - 12 as pos of field is 12
  EXECUTION_BLOCK_HASH_GINDEX_DENEB* = GeneralizedIndex(gIndexMidLevel * 1 * 32 + 12)

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
      electra.BeaconBlock
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
