# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# Example of how the beacon state historical_roots field could be provided with
# a Merkle proof that can be verified against the right beacon state root.
# These historical_roots with their proof could for example be provided over the
# network and verified on the receivers end.
#
# Note:
# Since Capella the historical_roots field is frozen. Thus providing the
# historical_roots with a Proof against the latest state seems a bit silly.
# One idea could be to embed it into the client just as is done for the
# execution header accumulator.
#

{.push raises: [].}

import
  stew/results,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/bellatrix

export results

type
  HistoricalRoots* = HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]
  HistoricalRootsProof* = array[5, Digest]
  HistoricalRootsWithProof* = object
    historical_roots: HistoricalRoots
    proof: HistoricalRootsProof

func buildProof*(
    state: ForkedHashedBeaconState): Result[HistoricalRootsProof, string] =
  let gIndex = GeneralizedIndex(39) # 31 + 8 = 39

  var proof: HistoricalRootsProof
  withState(state):
    ? forkyState.data.build_proof(gIndex, proof)

  ok(proof)

func verifyProof*(
    historical_roots: HistoricalRoots,
    proof: HistoricalRootsProof,
    stateRoot: Digest): bool =
  let
    gIndex = GeneralizedIndex(39)
    leave = hash_tree_root(historical_roots)

  verify_merkle_multiproof(@[leave], proof, @[gIndex], stateRoot)
