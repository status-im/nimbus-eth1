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

from ./eest_shared_releases import eestReleases

const
  baseFolder = "tests/fixtures"
  suiteName = "Evmstate Test"
  eestType = "state_tests"

const skipFiles = [
  # requires both tx.maxPriorityFeePerGas and tx.maxFeePerGas
  # of EIP-1559 as UInt256
  "admission_constraints.json"
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  parallelEnabled = true
)
