# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  beacon_chain/spec/forks,
  beacon_chain/spec/datatypes/capella,
  beacon_chain /../ tests/testblockutil,
  # Mock helpers
  beacon_chain /../ tests/mocking/mock_genesis,
  ../network/history/experimental/beacon_chain_block_proof_capella

# Test suite for the proofs:
# - historicalSummariesProof
# - BeaconBlockHeaderProof
# - BeaconBlockBodyProof
# and as last
# - the chain of proofs, BeaconChainBlockProof:
# BlockHash || BlockHeader
# -> BeaconBlockBodyProof
# -> BeaconBlockHeaderProof
# -> historicalSummariesProof
# historical_summaries
#
# Note: The last test makes the others redundant, but keeping them all around
# for now as it might be sufficient to go with just historicalSummariesProof
# (and perhaps BeaconBlockHeaderProof), see comments in beacon_chain_proofs.nim.
#
# TODO:
# - Add more blocks to reach 1+ historical summaries, to make sure that
# indexing is properly tested.
# - Adjust tests to test usage of historical_summaries and historical_roots
# together.

suite "Beacon Chain Block Proofs - Capella":
  let
    cfg = block:
      var res = defaultRuntimeConfig
      res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH
      res.BELLATRIX_FORK_EPOCH = GENESIS_EPOCH
      # res.CAPELLA_FORK_EPOCH = GENESIS_EPOCH
      res.CAPELLA_FORK_EPOCH = Epoch(256)
      res
    state = newClone(initGenesisState(cfg = cfg))
  var cache = StateCache()

  var blocks: seq[capella.SignedBeaconBlock]
  # Note:
  # Adding 8192*2 blocks. First block is genesis block and not one of these.
  # Then one extra block is needed to get the historical roots, block
  # roots and state roots processed.
  # index i = 0 is second block.
  # index i = 8190 is 8192th block and last one that is part of the first
  # historical root

  # genesis + 8191 slots, next one will be capella fork
  for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT - 1:
    discard addTestBlock(state[], cache, cfg = cfg)

  # slot 8192 -> 16383
  for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT:
    blocks.add(addTestBlock(state[], cache, cfg = cfg).capellaData)

  # One more slot to hit second SLOTS_PER_HISTORICAL_ROOT, hitting first
  # historical_summary.
  blocks.add(addTestBlock(state[], cache, cfg = cfg).capellaData)

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

  test "HistoricalRootsProof for BeaconBlockHeader":
    let blockRoots = getStateField(state[], block_roots).data

    withState(state[]):
      when consensusFork >= ConsensusFork.Capella:
        let historical_summaries = forkyState.data.historical_summaries

        # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
        for i in blocksToTest:
          let
            beaconBlock = blocks[i].message
            historicalRootsIndex = getHistoricalRootsIndex(beaconBlock.slot, cfg)
            blockRootIndex = getBlockRootsIndex(beaconBlock.slot)

          let res = buildProof(blockRoots, blockRootIndex)
          check res.isOk()
          let proof = res.get()

          check verifyProof(
            blocks[i].root,
            proof,
            historical_summaries[historicalRootsIndex].block_summary_root,
            blockRootIndex,
          )

  test "BeaconBlockHeaderProof for BeaconBlockBody":
    # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
    for i in blocksToTest:
      let
        beaconBlock = blocks[i].message
        beaconBlockHeader = BeaconBlockHeader(
          slot: beaconBlock.slot,
          proposer_index: beaconBlock.proposer_index,
          parent_root: beaconBlock.parent_root,
          state_root: beaconBlock.state_root,
          body_root: hash_tree_root(beaconBlock.body),
        )
        beaconBlockBody = beaconBlock.body

      let res = buildProof(beaconBlockHeader)
      check res.isOk()
      let proof = res.get()

      let leave = hash_tree_root(beaconBlockBody)
      check verifyProof(leave, proof, blocks[i].root)

  test "BeaconBlockBodyProof for Execution BlockHeader":
    # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
    for i in blocksToTest:
      let beaconBlockBody = blocks[i].message.body

      let res = buildProof(beaconBlockBody)
      check res.isOk()
      let proof = res.get()

      let leave = beaconBlockBody.execution_payload.block_hash
      let root = hash_tree_root(beaconBlockBody)
      check verifyProof(leave, proof, root)

  test "BeaconChainBlockProof for Execution BlockHeader":
    let blockRoots = getStateField(state[], block_roots).data

    withState(state[]):
      when consensusFork >= ConsensusFork.Capella:
        let historical_summaries = forkyState.data.historical_summaries

        # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
        for i in blocksToTest:
          let
            beaconBlock = blocks[i].message
            beaconBlockHeader = BeaconBlockHeader(
              slot: beaconBlock.slot,
              proposer_index: beaconBlock.proposer_index,
              parent_root: beaconBlock.parent_root,
              state_root: beaconBlock.state_root,
              body_root: hash_tree_root(beaconBlock.body),
            )
            beaconBlockBody = beaconBlock.body

            # Normally we would have an execution BlockHeader that holds this
            # value, but we skip the creation of that header for now and just take
            # the blockHash from the execution payload.
            blockHash = beaconBlockBody.execution_payload.block_hash

          let proofRes = buildProof(blockRoots, beaconBlockHeader, beaconBlockBody)
          check proofRes.isOk()
          let proof = proofRes.get()

          check verifyProof(historical_summaries, proof, blockHash, cfg)
