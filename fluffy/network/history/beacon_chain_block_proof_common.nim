# Fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import results, beacon_chain/spec/presets, beacon_chain/spec/forks

type BeaconBlockProof* = array[11, Digest]

func getBlockRootsIndex*(slot: Slot): uint64 =
  slot mod SLOTS_PER_HISTORICAL_ROOT

func getBlockRootsIndex*(beaconBlock: SomeForkyBeaconBlock): uint64 =
  getBlockRootsIndex(beaconBlock.slot)

# Builds proof to be able to verify that the EL block hash is part of the
# CL BeaconBlock for given root.
func buildProof*(blockBody: SomeForkyBeaconBlock): Result[BeaconBlockProof, string] =
  let
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
    gIndex = GeneralizedIndex(gIndexMidLevel * 1 * 16 + 12)

  var proof: BeaconBlockProof
  ?blockBody.build_proof(gIndex, proof)

  ok(proof)

func verifyProof*(blockHash: Digest, proof: BeaconBlockProof, blockRoot: Digest): bool =
  let
    gIndexTopLevel = (1 * 1 * 8 + 4)
    gIndexMidLevel = (gIndexTopLevel * 1 * 16 + 9)
    gIndex = GeneralizedIndex(gIndexMidLevel * 1 * 16 + 12)

  verify_merkle_multiproof(@[blockHash], proof, @[gIndex], blockRoot)
