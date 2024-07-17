# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
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
  ../../../common/common_types,
  ../../../network/history/experimental/beacon_chain_block_proof_capella,
  ../../../network/beacon/beacon_init_loader,
  ../../../eth_data/[yaml_utils, yaml_eth_types]

proc toString(v: IoErrorCode): string =
  try:
    ioErrorMsg(v)
  except Exception as e:
    raiseAssert e.msg

# Testing only proc as in the real network the historical_summaries are
# retrieved from the network.
proc readHistoricalSummaries(
    file: string
): Result[HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT], string] =
  let encodedHistoricalSummaries = ?readAllFile(file).mapErr(toString)

  try:
    ok(
      SSZ.decode(
        encodedHistoricalSummaries,
        HashList[HistoricalSummary, Limit HISTORICAL_ROOTS_LIMIT],
      )
    )
  except SerializationError as err:
    err("Failed decoding historical_summaries: " & err.msg)

suite "History Block Proofs - Capella":
  test "BeaconChainBlockProof for Execution BlockHeader":
    let
      testsPath =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/block_proofs_capella/"
      historicalSummaries_path =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/block_proofs_capella/historical_summaries_at_slot_8953856.ssz"
      networkData = loadNetworkData("mainnet")
      historicalSummaries = readHistoricalSummaries(historicalSummaries_path).valueOr:
        raiseAssert "Cannot read historical summaries: " & error

    # TODO: reactivate when test vectors PR gets merged
    skip()
    # for kind, path in walkDir(testsPath):
    #   if kind == pcFile and path.splitFile.ext == ".yaml":
    #     let
    #       testProof = YamlTestProof.loadFromYaml(path).valueOr:
    #         raiseAssert "Cannot read test vector: " & error

    #       blockHash = BlockHash.fromHex(testProof.execution_block_header)
    #       blockProof = BeaconChainBlockProof(
    #         beaconBlockProof: array[11, Digest].fromHex(testProof.beacon_block_proof),
    #         beaconBlockRoot: Digest.fromHex(testProof.beacon_block_root),
    #         historicalSummariesProof:
    #           array[13, Digest].fromHex(testProof.historical_summaries_proof),
    #         slot: Slot(testProof.slot),
    #       )

    #     check verifyProof(
    #       historicalSummaries, blockProof, blockHash, networkData.metadata.cfg
    #     )
