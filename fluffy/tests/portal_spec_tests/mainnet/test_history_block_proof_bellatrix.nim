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
  ../../test_yaml_utils

type YamlTestProof = object
  execution_block_header: string # Not part of the actual proof
  beacon_block_body_proof: array[8, string]
  beacon_block_body_root: string
  beacon_block_header_proof: array[3, string]
  beacon_block_header_root: string
  historical_roots_proof: array[14, string]
  slot: uint64

proc fromHex[n](T: type array[n, Digest], a: array[n, string]): T =
  var res: T
  for i in 0 ..< a.len:
    res[i] = Digest.fromHex(a[i])

  res

suite "History Block Proofs - Bellatrix":
  test "BeaconChainBlockProof for Execution BlockHeader":
    let
      testsPath =
        "./vendor/portal-spec-tests/tests/mainnet/history/headers_with_proof/block_proofs_bellatrix/"
      historicalRoots = loadHistoricalRoots()

    for kind, path in walkDir(testsPath):
      if kind == pcFile and path.splitFile.ext == ".yaml":
        let
          testProof = YamlTestProof.loadFromYaml(path).valueOr:
            raiseAssert "Cannot read test vector: " & error

          blockHash = BlockHash.fromHex(testProof.execution_block_header)
          blockProof = BeaconChainBlockProof(
            beaconBlockBodyProof:
              array[8, Digest].fromHex(testProof.beacon_block_body_proof),
            beaconBlockBodyRoot: Digest.fromHex(testProof.beacon_block_body_root),
            beaconBlockHeaderProof:
              array[3, Digest].fromHex(testProof.beacon_block_header_proof),
            beaconBlockHeaderRoot: Digest.fromHex(testProof.beacon_block_header_root),
            historicalRootsProof:
              array[14, Digest].fromHex(testProof.historical_roots_proof),
            slot: Slot(testProof.slot),
          )

        check verifyProof(historicalRoots, blockProof, blockHash)
