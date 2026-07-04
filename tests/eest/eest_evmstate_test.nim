# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/os,
  ./eest_runner,
  ./eest_evmstate

const
  baseFolder = "tests/fixtures"
  suiteName = "Evmstate Test"
  eestType = "state_tests"
  eestReleases = [
    "eest_mainnet",
    "eest_devnet",
  ]

const skipFiles = [
  ""
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  parallelEnabled = true
)
