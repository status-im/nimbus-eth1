# fluffy
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  beacon_chain/spec/forks,
  # Test helpers
  beacon_chain /../ tests/testblockutil,
  beacon_chain /../ tests/mocking/mock_genesis,
  beacon_chain /../ tests/consensus_spec/fixtures_utils,
  ../../network/beacon/beacon_chain_historical_summaries

suite "Beacon Chain Historical Summaries":
  let
    cfg = genesisTestRuntimeConfig(ConsensusFork.Capella)
    state = newClone(initGenesisState(cfg = cfg))
  var cache = StateCache()

  var blocks: seq[capella.SignedBeaconBlock]
  # Note:
  # Adding 8192 blocks. First block is genesis block and not one of these.
  # Then one extra block is needed to get the historical summaries, block
  # roots and state roots processed.
  # index i = 0 is second block.
  # index i = 8190 is 8192th block and last one that is part of the first
  # historical root
  for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT:
    blocks.add(addTestBlock(state[], cache, cfg = cfg).capellaData)

  test "Historical Summaries Proof":
    withState(state[]):
      when consensusFork >= ConsensusFork.Capella:
        let historical_summaries = forkyState.data.historical_summaries
        let res = buildProof(state[])
        check res.isOk()
        let proof = res.get()

        withState(state[]):
          check verifyProof(historical_summaries, proof, forkyState.root)
