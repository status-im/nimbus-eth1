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
  ./eest_helpers,
  ./eest_blockchain

const
  baseFolder = "tests/fixtures"
  eestType = "blockchain_tests"
  eestReleases = [
    "eest_develop",
    # TODO: zkevm@v0.3.3 is not compatible with bal@v5.7.0
    # enable this when they become compatible again
    # "eest_zkevm"
  ]

const skipFiles = [
  # Currently skipped as still failing with statelessEnabled = true
  # Once all of these pass we could simply run eest_blockchain_test.nim
  # with statelessEnabled = true and remove this test file.
  #
  # --- eest_develop files with failures ---
  #
  "test_scenarios.json", # persist assert
  #
  # --- eest_zkevm files with failures ---
  #
  "varying_calldata_costs.json", # Witness state mismatch
  "witness_codes_delegated_eoa_insufficient_balance.json", # blockAccessListHash mismatch
  "witness_codes_create_same_hash_then_read.json", # Witness codes mismatch
  "witness_headers_blockhash_boundary.json", # Witness state mismatch
  "witness_state_block_diff_delete_insert_before_delete_order.json", # persistStorage assert
  "genesis_hash_available.json", # Witness state mismatch
  "scenarios.json", # Witness state mismatch + stateRoot mismatch
  "withdrawal_requests.json", # persistStorage assert + Witness state mismatch
  "consolidation_requests.json", # Witness state mismatch
  "multiple_withdrawals_same_address.json", # Witness state mismatch
  "return_bounds.json", # Witness state mismatch
  "validation_codes_missing_delegated_code_on_insufficient_balance_call.json", # blockAccessListHash mismatch
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
