# Nimbus
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# Implementation of beacon state historical_roots field with a Merkle proof
# that can be verified against the right beacon state root.
# These historical_roots with their proof could for example be provided over the
# network and verified on the receivers end.
#
# Note:
# Since Capella the historical_roots field is frozen. Because of this
# the historical_roots are currently embedded inside the client. And could
# simply be verified by checking its root.
# Thus HistoricalRootsWithProof is currently unused. It could be embedded
# with its proof and/or send over the network.
# The proof supported is only the version from >= Electra as it would only
# make sense to verify it against a recent state.
#

{.push raises: [].}

import results, stew/bitops2, beacon_chain/spec/forks

export results

const HISTORICAL_ROOTS_GINDEX_ELECTRA* =
  get_generalized_index(electra.BeaconState, "historical_roots")

static:
  doAssert HISTORICAL_ROOTS_GINDEX_ELECTRA == 71.GeneralizedIndex

  for consensusFork in ConsensusFork:
    withConsensusFork(consensusFork):
      if consensusFork >= ConsensusFork.Electra:
        template check(gindex, T: untyped, path: varargs[untyped]): untyped =
          doAssert gindex == consensusFork.T.get_generalized_index(path)

        check HISTORICAL_ROOTS_GINDEX_ELECTRA, BeaconState, "historical_roots"

type
  HistoricalRoots* = HashList[Eth2Digest, Limit HISTORICAL_ROOTS_LIMIT]
  HistoricalRootsProof* = array[log2trunc(HISTORICAL_ROOTS_GINDEX_ELECTRA), Digest]
  HistoricalRootsWithProof* = object
    historical_roots: HistoricalRoots
    proof: HistoricalRootsProof

func buildProof*(state: ForkedHashedBeaconState): Result[HistoricalRootsProof, string] =
  var proof: HistoricalRootsProof
  withState(state):
    ?forkyState.data.build_proof(HISTORICAL_ROOTS_GINDEX_ELECTRA, proof)

  ok(proof)

func verifyProof*(
    historical_roots: HistoricalRoots, proof: HistoricalRootsProof, stateRoot: Digest
): bool =
  let leave = hash_tree_root(historical_roots)

  verify_merkle_multiproof(
    @[leave], proof, @[HISTORICAL_ROOTS_GINDEX_ELECTRA], stateRoot
  )
