# fluffy
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#
# Implementation of the beacon state historical_summaries provided with a Merkle
# proof that can be verified against the right beacon state root.
#
# As per spec:
# https://github.com/ethereum/portal-network-specs/blob/master/beacon-chain/beacon-network.md#historicalsummaries
#

{.push raises: [].}

import stew/arrayops, results, beacon_chain/spec/forks, ../../common/common_types

from stew/bitops2 import log2trunc

export results

const HISTORICAL_SUMMARIES_GINDEX_ELECTRA* = GeneralizedIndex(91)

type
  HistoricalSummaries* = HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT]
  HistoricalSummariesProof* =
    array[log2trunc(HISTORICAL_SUMMARIES_GINDEX_ELECTRA), Digest]
  HistoricalSummariesWithProof* = object
    epoch*: Epoch
    # TODO:
    # can epoch instead of slot cause any issues? E.g. to verify with right state?
    # To revise when we fully implement this in validateHistoricalSummaries,
    # for now follow specification.
    # finalized_slot*: Slot
    historical_summaries*: HistoricalSummaries
    proof*: HistoricalSummariesProof

func encodeSsz*(obj: HistoricalSummariesWithProof, forkDigest: ForkDigest): seq[byte] =
  var res: seq[byte]
  res.add(distinctBase(forkDigest))
  res.add(SSZ.encode(obj))

  res

func decodeSsz*(
    forkDigests: ForkDigests,
    data: openArray[byte],
    T: type HistoricalSummariesWithProof,
): Result[HistoricalSummariesWithProof, string] =
  if len(data) < 4:
    return
      Result[HistoricalSummariesWithProof, string].err("Not enough data for forkDigest")

  let
    forkDigest = ForkDigest(array[4, byte].initCopyFrom(data))
    contextFork = forkDigests.consensusForkForDigest(forkDigest).valueOr:
      return Result[HistoricalSummariesWithProof, string].err("Unknown fork")

  if contextFork >= ConsensusFork.Electra:
    # As only the very latest version of the historical_summaries is useful for
    # the node it doesn't make sense to support older forks for the proofs.
    decodeSsz(data.toOpenArray(4, len(data) - 1), HistoricalSummariesWithProof)
  else:
    Result[HistoricalSummariesWithProof, string].err(
      "Invalid Fork for HistoricalSummaries"
    )

func buildProof*(
    state: ForkedHashedBeaconState
): Result[HistoricalSummariesProof, string] =
  var proof: HistoricalSummariesProof
  withState(state):
    ?forkyState.data.build_proof(HISTORICAL_SUMMARIES_GINDEX_ELECTRA, proof)

  ok(proof)

func verifyProof*(
    historical_summaries: HistoricalSummaries,
    proof: HistoricalSummariesProof,
    stateRoot: Digest,
): bool =
  let leave = hash_tree_root(historical_summaries)

  verify_merkle_multiproof(
    @[leave], proof, @[HISTORICAL_SUMMARIES_GINDEX_ELECTRA], stateRoot
  )

func verifyProof*(
    summariesWithProof: HistoricalSummariesWithProof, stateRoot: Digest
): bool =
  verifyProof(
    summariesWithProof.historical_summaries, summariesWithProof.proof, stateRoot
  )
