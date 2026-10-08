# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/os,
  unittest2,
  ./eest_runner,
  ./eest_blockchain

const
  baseFolder = "tests/fixtures"
  suiteName = "ZkEVM Benchmark Test"
  eestType = "blockchain_tests"
  eestReleases = [
    "eest_zkevm_benchmark",
  ]

# Filled with geth, which is not spec compliant here: it adds code that is
# created within the block to the execution witness.
const skipFiles = [
  "storage_access_cold.json",
  "selfdestruct_created.json",
  "deploy_then_interact.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  statelessEnabled = true,
  parallelEnabled = false # Stateless features are not supported with parallel enabled
)
