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
  suiteName = "Benchmark Test"
  eestType = "blockchain_tests"
  eestReleases = [
    "eest_benchmark",
  ]

const skipFiles = [
  "",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  testFilter = "*keccak*",
  parallelEnabled = false
)
