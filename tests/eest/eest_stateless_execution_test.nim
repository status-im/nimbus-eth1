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
    "eest_zkevm"
  ]

const skipFiles = [
  # Currently skipped as still failing with statelessEnabled = true
  # Once all of these pass we could simply run eest_blockchain_test.nim
  # with statelessEnabled = true and remove this test file.
  #
  # --- eest_zkevm files with failures ---
  #
  # `dst.contains(k)`  [AssertionDefect] -> on execution of test vector witness
  #  generated witness has an extra state node, stateless execution works with it
  "varying_calldata_costs.json",
  "witness_headers_blockhash_boundary.json",
  "genesis_hash_available.json",
  "scenarios.json",
  "withdrawal_requests.json",
  "consolidation_requests.json",
  "multiple_withdrawals_same_address.json",
  "return_bounds.json",
  #
  # persistStorage(): Unspecified(Aristo, ctx=, error=DelVidStaleVtx) [AssertionDefect]
  # -> on execution with test vector witness
  # generated witness has an extra state node, stateless execution works with it
  "witness_state_block_diff_delete_insert_before_delete_order.json",
  #
  # Witness codes mismatch -> codes optimisation: implemented in
  # https://github.com/status-im/nimbus-eth1/pull/4099
  "witness_codes_create_same_hash_then_read.json",
  #
  # blockAccessListHash mismatch, not an stateless execution failure.
  # Likely an issue on reference implementation side
  "witness_codes_delegated_eoa_insufficient_balance.json",
  "validation_codes_missing_delegated_code_on_insufficient_balance_call.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
