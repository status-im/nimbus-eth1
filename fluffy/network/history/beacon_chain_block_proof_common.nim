# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, beacon_chain/spec/presets, beacon_chain/spec/forks

type
  BeaconBlockBodyProof* = array[8, Digest]
  BeaconBlockHeaderProof* = array[3, Digest]

func getBlockRootsIndex*(slot: Slot): uint64 =
  slot mod SLOTS_PER_HISTORICAL_ROOT

func getBlockRootsIndex*(blockHeader: BeaconBlockHeader): uint64 =
  getBlockRootsIndex(blockHeader.slot)

# Builds proof to be able to verify that the EL block hash is part of
# BeaconBlockBody for given root.
func buildProof*(
    blockBody: ForkyTrustedBeaconBlockBody | ForkyBeaconBlockBody
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
