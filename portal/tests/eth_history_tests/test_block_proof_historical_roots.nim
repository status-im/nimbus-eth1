# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  beacon_chain/spec/forks,
  # Mock helpers
  beacon_chain /../ tests/testblockutil,
  beacon_chain /../ tests/mocking/mock_genesis,
  ../../eth_history/block_proofs/block_proof_historical_roots

# Test suite for the chain of proofs BlockProofHistoricalRoots:
# -> BeaconBlockProofHistoricalRoots
# -> ExecutionBlockProof
#
# Note: Only the full chain of proofs is tested here. The setup takes a lot of time
# and testing the individual proofs is redundant.

suite "History Block Proofs - Historical Roots":
  setup:
    let
      cfg = block:
        var res = defaultRuntimeConfig
        res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH
        res.BELLATRIX_FORK_EPOCH = GENESIS_EPOCH
        res
      state = newClone(initGenesisState(cfg = cfg))
    var cache = StateCache()

    var blocks: seq[bellatrix.SignedBeaconBlock]
    # Note:
    # Adding 8192 blocks. First block is genesis block and not one of these.
    # Then one extra block is needed to get the historical roots, block
    # roots and state roots processed.
    # index i = 0 is second block.
    # index i = 8190 is 8192th block and last one that is part of the first
    # historical root

    # genesis + 8191 slots
    for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT - 1:
      blocks.add(addTestBlock(state[], cache, cfg = cfg).bellatrixData)

    # One more slot to hit second SLOTS_PER_HISTORICAL_ROOT, hitting first
    # historical root.
    discard addTestBlock(state[], cache, cfg = cfg)

    # Starts from the block after genesis.
    const blocksToTest = [
      0'u64,
      1,
      2,
      3,
      SLOTS_PER_HISTORICAL_ROOT div 2,
      SLOTS_PER_HISTORICAL_ROOT - 3,
      SLOTS_PER_HISTORICAL_ROOT - 2,
    ]

  test "BlockProofHistoricalRoots for Execution BlockHeader":
    let
      # Historical batch of first historical root
      batch = HistoricalBatch(
        block_roots: getStateField(state[], block_roots).data,
        state_roots: getStateField(state[], state_roots).data,
      )
      historical_roots = getStateField(state[], historical_roots)

    # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
    for i in blocksToTest:
      let
        beaconBlock = blocks[i].message
        # Normally we would have an execution BlockHeader that holds this
        # value, but we skip the creation of that header for now and just take
        # the blockHash from the execution payload.
        blockHash = beaconBlock.body.execution_payload.block_hash

      let proofRes = buildProof(batch, beaconBlock)
      check proofRes.isOk()
      let proof = proofRes.get()

      check verifyProof(historical_roots, proof, blockHash)
