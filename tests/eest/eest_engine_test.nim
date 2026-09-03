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

  # blobGasUSed
  "insufficient_balance_blob_tx_combinations.json",
  "invalid_blob_hash_versioning_multiple_txs.json",
  "invalid_blob_hash_versioning_single_tx.json",
  "invalid_block_blob_count.json",
  "invalid_tx_blob_count.json",
  "invalid_tx_max_fee_per_blob_gas.json",
  "invalid_normal_gas.json",

  # BAL
  "tx_gas_limit.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  parallelEnabled = true
)
