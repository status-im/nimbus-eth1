# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/os,
  unittest2,
  ./eest_helpers,
  ./eest_engine

const
  baseFolder = "tests/fixtures"
  eestType = "blockchain_tests_engine"
  eestReleases = [
    "eest_develop",
    "eest_devnet",
    "eest_bal"
  ]

const skipFiles = [
  "CALLBlake2f_MaxRounds.json", # Doesn't work in github CI
  "consolidation_requests.json",
  "withdrawal_requests.json",
  "bal_call_and_oog.json",
  "bal_delegatecall_and_oog.json",
  "value_transfer_gas_calculation.json"
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType
)
