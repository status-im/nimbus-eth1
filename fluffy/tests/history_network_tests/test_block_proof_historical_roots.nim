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
  beacon_chain/spec/datatypes/bellatrix,
  beacon_chain /../ tests/testblockutil,
  # Mock helpers
  beacon_chain /../ tests/mocking/mock_genesis,
  ../../network/history/validation/block_proof_historical_roots

# Test suite for the proofs:
# - HistoricalRootsProof
# - BeaconBlockProof
# and:
# - the chain of both proofs, BeaconChainBlockProof:
# BlockHash
# -> BeaconBlockProof
# -> HistoricalRootsProof
# historical_roots
#
# Note: The last test makes the others redundant, but keeping them all around
# for now as it might be sufficient to go with just HistoricalRootsProof (and
# perhaps BeaconBlockHeaderProof), see comments in beacon_chain_proofs.nim.
#
# TODO: Add more blocks to reach 1+ historical roots, to make sure that indexing
# is properly tested.

suite "Beacon Chain Block Proofs - Bellatrix":
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
  for i in 0 ..< SLOTS_PER_HISTORICAL_ROOT:
    blocks.add(addTestBlock(state[], cache, cfg = cfg).bellatrixData)

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

  test "BeaconBlockProofHistoricalRoots for BeaconBlock":
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
        historicalRootsIndex = getHistoricalRootsIndex(beaconBlock.slot)
        blockRootIndex = getBlockRootsIndex(beaconBlock.slot)

      let res = buildProof(batch, blockRootIndex)
      check res.isOk()
      let proof = res.get()

      check verifyProof(
        blocks[i].root, proof, historical_roots[historicalRootsIndex], blockRootIndex
      )

  test "ExecutionBlockProof for Execution BlockHeader":
    # for i in 0..<(SLOTS_PER_HISTORICAL_ROOT - 1): # Test all blocks
    for i in blocksToTest:
      let beaconBlock = blocks[i].message

      let res = buildProof(beaconBlock)
      check res.isOk()
      let proof = res.get()

      let leave = beaconBlock.body.execution_payload.block_hash
      check verifyProof(leave, proof, blocks[i].root)

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
