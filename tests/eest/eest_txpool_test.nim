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
  ./eest_helpers,
  ./eest_txpool

const
  baseFolder = "tests/fixtures"
  eestType = "blockchain_tests"
  eestReleases = [
    "eest_develop",
    "eest_bal"
  ]

const skipFiles = [
  "",
  # This is a case where the parent block have excess blob gas
  # greater than expected. Not a bug anywhere, but part of the txpool
  # algorithm is calculating the next block excess blob gas from
  # the parent, so there is no way this test intended for block execution
  # will pass when executed by txpool. It's already amazing we only need
  # to skip one fixture file.
  "test_correct_decreasing_blob_gas_costs.json",

  # TODO: remove this entry after we have EEST new release for glamsterdam-devnet-7
  "bal_call_revert_insufficient_funds.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  parallelEnabled = true
)
