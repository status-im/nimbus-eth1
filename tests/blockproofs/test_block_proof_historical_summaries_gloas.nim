# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  unittest2,
  beacon_chain/spec/forks,
  ../../execution_chain/history/block_proofs/block_proof_historical_summaries

# Test suite for the chain of proofs BlockProofHistoricalSummariesGloas:
# -> BeaconBlockProofHistoricalSummaries
# -> ExecutionBlockProofGloas
#
# From Gloas onwards the proof is built from the block that confirms the
# payload rather than the one that commits to it, see `block_proof_common.nim`.
#
# Note: unlike the pre-Gloas suites these blocks are not produced by a state
# transition, as only the shape of the block matters for the proofs. The
# block_roots and the historical summary that anchors them are built here.

suite "History Block Proofs - Historical Summaries - Gloas":
  setup:
    let
      cfg = block:
        var res = defaultRuntimeConfig
        res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH
        res.BELLATRIX_FORK_EPOCH = GENESIS_EPOCH
        res.CAPELLA_FORK_EPOCH = GENESIS_EPOCH
        res.DENEB_FORK_EPOCH = GENESIS_EPOCH
        res.ELECTRA_FORK_EPOCH = GENESIS_EPOCH
        res.FULU_FORK_EPOCH = GENESIS_EPOCH
        res.GLOAS_FORK_EPOCH = GENESIS_EPOCH
        res

      # The execution block that is proven: confirmed by the block that builds
      # on it, and thus the `parent_block_hash` of that block's bid.
      confirmedBlockHash = Digest.fromHex(
        "0x1111111111111111111111111111111111111111111111111111111111111111"
      )
      # The payload that same block commits to. It may never be revealed, so it
      # must not be provable.
      committedBlockHash = Digest.fromHex(
        "0x2222222222222222222222222222222222222222222222222222222222222222"
      )

    const slotsToTest =
      [1'u64, 2, 3, SLOTS_PER_HISTORICAL_ROOT div 2, SLOTS_PER_HISTORICAL_ROOT - 1]

    proc confirmingBlock(slot: uint64): gloas.BeaconBlock =
      ## Block that confirms `confirmedBlockHash` while committing to a payload
      ## of its own.
      var blck = default(gloas.BeaconBlock)
      blck.slot = Slot(slot)
      blck.body.signed_execution_payload_bid.message.parent_block_hash =
        confirmedBlockHash
      blck.body.signed_execution_payload_bid.message.block_hash = committedBlockHash
      blck

    proc historicalSummariesAt(
        blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest], era: int
    ): HistoricalSummaries =
      ## Summaries in which `blockRoots` is the summary of `era`, with
      ## placeholders for the eras before it.
      var summaries: HistoricalSummaries
      for _ in 0 ..< era:
        discard summaries.add(HistoricalSummary())
      discard
        summaries.add(HistoricalSummary(block_summary_root: hash_tree_root(blockRoots)))
      summaries

    proc historicalSummaries(
        blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    ): HistoricalSummaries =
      historicalSummariesAt(blockRoots, 0)

  test "BlockProofHistoricalSummariesGloas for Execution BlockHeader":
    for slot in slotsToTest:
      let beaconBlock = confirmingBlock(slot)

      var blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
      blockRoots[slot] = hash_tree_root(beaconBlock)

      let
        summaries = historicalSummaries(blockRoots)
        proof = buildProof(blockRoots, beaconBlock).expect("valid proof")

      check:
        proof.slot == Slot(slot)
        proof.beaconBlockRoot == hash_tree_root(beaconBlock)
        verifyProof(summaries, proof, confirmedBlockHash, cfg)

  test "BlockProofHistoricalSummariesGloas - committed payload is not provable":
    # A payload that a block commits to is not canonical until a later block
    # confirms it, so the block hash in the bid must not verify.
    let beaconBlock = confirmingBlock(1)

    var blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    blockRoots[1] = hash_tree_root(beaconBlock)

    let
      summaries = historicalSummaries(blockRoots)
      proof = buildProof(blockRoots, beaconBlock).expect("valid proof")

    check:
      not verifyProof(summaries, proof, committedBlockHash, cfg)
      not verifyProof(summaries, proof, default(Digest), cfg)

  test "BlockProofHistoricalSummariesGloas - confirming block in the next era":
    # A payload committed to at the end of an era is confirmed by a block of the
    # next era, so the proof anchors in the summary of that next era.
    const confirmingSlot = uint64(SLOTS_PER_HISTORICAL_ROOT) # first slot of era 1
    let beaconBlock = confirmingBlock(confirmingSlot)

    var blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    blockRoots[0] = hash_tree_root(beaconBlock)

    let
      summaries = historicalSummariesAt(blockRoots, 1)
      proof = buildProof(blockRoots, beaconBlock).expect("valid proof")

    check:
      proof.slot == Slot(confirmingSlot)
      verifyProof(summaries, proof, confirmedBlockHash, cfg)
      # Summaries that do not reach the era of the confirming block
      not verifyProof(
        historicalSummariesAt(blockRoots, 0), proof, confirmedBlockHash, cfg
      )

  test "BlockProofHistoricalSummariesGloas - block not in block_roots":
    let beaconBlock = confirmingBlock(1)

    var blockRoots: array[SLOTS_PER_HISTORICAL_ROOT, Eth2Digest]
    blockRoots[2] = hash_tree_root(beaconBlock) # wrong slot

    let
      summaries = historicalSummaries(blockRoots)
      proof = buildProof(blockRoots, beaconBlock).expect("valid proof")

    check not verifyProof(summaries, proof, confirmedBlockHash, cfg)
