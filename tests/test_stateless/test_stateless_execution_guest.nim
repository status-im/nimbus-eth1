# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, strutils],
  unittest2,
  ../../execution_chain/common,
  ../../execution_chain/db/core_db/memory_only,
  ../../execution_chain/stateless/[stateless_execution, stateless_execution_helpers]

const
  sourcePath = currentSourcePath.rsplit({DirSep, AltSep}, 1)[0]
  networkId = MainNet

proc nodeCommonRef(): CommonRef =
  # As a node running `statelessWitnessValidation` passes it.
  CommonRef.new(AristoDbMemory.newCoreDbRef(), statelessProvider = true)

proc guestCommonRef(): CommonRef =
  # As the zkVM guest uses it: no database at all.
  CommonRef.new(
    db = nil,
    config = chainConfigForNetwork(networkId),
    networkId = networkId,
    initializeDb = false,
  )

suite "Stateless Execution Tests - Guest Only":
  test "Stateless process block json files - mainnet block 100":
    let
      witnessJsonFile = sourcePath / "mainnet_100_witness.json"
      blkJsonFile = sourcePath / "mainnet_100_block.json"
    check statelessProcessBlockJsonFiles(witnessJsonFile, nodeCommonRef(), blkJsonFile).isOk()
    check statelessProcessBlockJsonFiles(witnessJsonFile, guestCommonRef(), blkJsonFile).isOk()

  test "Stateless process block json files - mainnet block 73141":
    let
      witnessJsonFile = sourcePath / "mainnet_73141_witness.json"
      blkJsonFile = sourcePath / "mainnet_73141_block.json"
    check statelessProcessBlockJsonFiles(witnessJsonFile, nodeCommonRef(), blkJsonFile).isOk()
    check statelessProcessBlockJsonFiles(witnessJsonFile, guestCommonRef(), blkJsonFile).isOk()
