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
  unittest2,
  yaml,
  beacon_chain/spec/datatypes/bellatrix,
  ../../../common/common_types,
  ../../../network_metadata,
  ../../../network/history/beacon_chain_block_proof_bellatrix,
  ../../../eth_data/[yaml_utils, yaml_eth_types]

suite "History Block Proofs - Bellatrix":
  test "BeaconChainBlockProof for Execution BlockHeader":
    let
      testsPath =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/block_proofs_bellatrix/"
      historicalRoots = loadHistoricalRoots()

    # TODO: reactivate when test vectors PR gets merged
    skip()
    # for kind, path in walkDir(testsPath):
    #   if kind == pcFile and path.splitFile.ext == ".yaml":
    #     let
    #       testProof = YamlTestProofBellatrix.loadFromYaml(path).valueOr:
    #         raiseAssert "Cannot read test vector: " & error

    #       blockHash = BlockHash.fromHex(testProof.execution_block_header)
    #       blockProof = BeaconChainBlockProof(
    #         beaconBlockProof: array[11, Digest].fromHex(testProof.beacon_block_proof),
    #         beaconBlockRoot: Digest.fromHex(testProof.beacon_block_root),
    #         historicalRootsProof:
    #           array[14, Digest].fromHex(testProof.historical_roots_proof),
    #         slot: Slot(testProof.slot),
    #       )

    #     check verifyProof(historicalRoots, blockProof, blockHash)
