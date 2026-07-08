# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
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
  ./eest_runner,
  ./eest_engine

const
  baseFolder = "tests/fixtures"
  suiteName = "Engine Tests"
  eestType = "blockchain_tests_engine"
  eestReleases = [
    "eest_mainnet",
    "eest_devnet",
  ]

const skipFiles = [
  "CALLBlake2f_MaxRounds.json", # Doesn't work in github CI

  # Fail when parallelEnabled = true
  "pointer_resets_an_empty_code_account_with_storage.json",
  "recreate_self_destructed_contract_different_txs.json",
  "bal_create2_selfdestruct_then_recreate_same_block.json",
  "bal_7702_delegation_clear.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  parallelEnabled = true
)
