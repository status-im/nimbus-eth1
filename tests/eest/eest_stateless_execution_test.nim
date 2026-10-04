# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  suiteName = "Stateless Execution Test"
  eestType = "blockchain_tests"
  eestReleases = [
    "eest_zkevm",
    "eest_zkevm_benchmark"
  ]

# Witness generation failures:
# - storage_access_cold: missing 7702 delegation designator code
# - deploy_then_interact: missing code deployed within the block + one with too many state nodes
# - selfdestruct_created: missing code of created contract
# TBI
const skipFiles = [
  "eest_zkevm_benchmark/blockchain_tests/for_amsterdam_at_0030M/compute/instruction/storage/storage_access_cold.json",
  "eest_zkevm_benchmark/blockchain_tests/for_amsterdam_at_0030M/compute/instruction/system/selfdestruct_created.json",
  "eest_zkevm_benchmark/blockchain_tests/for_amsterdam_at_0030M/compute/eip7928_block_level_access_lists/block_access_list/deploy_then_interact.json",
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
