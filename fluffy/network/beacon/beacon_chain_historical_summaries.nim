# fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# Example of how the beacon state historical_summaries field could be provided
# with a Merkle proof that can be verified against the right beacon state root.
# These historical_summaries with their proof could for example be provided over
# the network and verified on the receivers end.
#

{.push raises: [].}

import
  stew/results,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/capella

export results

type
  HistoricalSummaries* = HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT]
  HistoricalSummariesProof* = array[5, Digest]
  HistoricalSummariesWithProof* = object
    finalized_slot*: Slot
    historical_summaries*: HistoricalSummaries
    proof*: HistoricalSummariesProof

func buildProof*(
    state: ForkedHashedBeaconState): Result[HistoricalSummariesProof, string] =
  let gIndex = GeneralizedIndex(59) # 31 + 28 = 59

  var proof: HistoricalSummariesProof
  withState(state):
    ? forkyState.data.build_proof(gIndex, proof)

  ok(proof)

func verifyProof*(
    historical_summaries: HistoricalSummaries,
    proof: HistoricalSummariesProof,
    stateRoot: Digest): bool =
  let
    gIndex = GeneralizedIndex(59)
    leave = hash_tree_root(historical_summaries)

  verify_merkle_multiproof(@[leave], proof, @[gIndex], stateRoot)

func verifyProof*(
    summariesWithProof: HistoricalSummariesWithProof,
    stateRoot: Digest): bool =
  verifyProof(
    summariesWithProof.historical_summaries, summariesWithProof.proof, stateRoot)
