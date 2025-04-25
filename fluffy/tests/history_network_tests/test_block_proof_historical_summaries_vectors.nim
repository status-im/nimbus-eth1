# Fluffy
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

{.push raises: [].}

import
  std/os,
  stew/io2,
  unittest2,
  yaml,
  ssz_serialization,
  beacon_chain/spec/datatypes/capella,
  ../../network/history/validation/block_proof_historical_summaries,
  ../../network/beacon/beacon_init_loader,
  ../../eth_data/[yaml_utils, yaml_eth_types],
  ./test_history_util

suite "History Block Proofs - Historical Summaries - Test Vectors":
  test "BlockProofHistoricalSummaries for Execution BlockHeader":
    let
      testsPath =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/block_proofs_capella/"
      historicalSummaries_path =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/beacon_data/historical_summaries_at_slot_11476992.ssz"
      networkData = loadNetworkData("mainnet")
      historicalSummaries = readHistoricalSummaries(historicalSummaries_path).valueOr:
        raiseAssert "Cannot read historical summaries: " & error

    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          testProof = YamlTestProofCapella.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          blockHash = Digest.fromHex(testProof.execution_block_header)
          blockProof = BlockProofHistoricalSummaries(
            beaconBlockProof: array[13, Digest].fromHex(testProof.beacon_block_proof),
            beaconBlockRoot: Digest.fromHex(testProof.beacon_block_root),
            executionBlockProof: ExecutionBlockProof(
              array[11, Digest].fromHex(testProof.execution_block_proof)
            ),
            slot: Slot(testProof.slot),
          )

        check verifyProof(
          historicalSummaries, blockProof, blockHash, networkData.metadata.cfg
        )

  test "BlockProofHistoricalSummariesDeneb for Execution BlockHeader":
    let
      testsPath =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/block_proofs_deneb/"
      historicalSummaries_path =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/beacon_data/historical_summaries_at_slot_11476992.ssz"
      networkData = loadNetworkData("mainnet")
      historicalSummaries = readHistoricalSummaries(historicalSummaries_path).valueOr:
        raiseAssert "Cannot read historical summaries: " & error

    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          testProof = YamlTestProofDeneb.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          blockHash = Digest.fromHex(testProof.execution_block_header)
          blockProof = BlockProofHistoricalSummariesDeneb(
            beaconBlockProof: array[13, Digest].fromHex(testProof.beacon_block_proof),
            beaconBlockRoot: Digest.fromHex(testProof.beacon_block_root),
            executionBlockProof: ExecutionBlockProofDeneb(
              array[12, Digest].fromHex(testProof.execution_block_proof)
            ),
            slot: Slot(testProof.slot),
          )

        check verifyProof(
          historicalSummaries, blockProof, blockHash, networkData.metadata.cfg
        )
