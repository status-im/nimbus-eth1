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
    "eest_zkevm"
  ]

const skipFiles = [
  # Currently skipped as still failing with statelessEnabled = true
  # Once all of these pass we could simply run eest_blockchain_test.nim
  # with statelessEnabled = true and remove this test file.
  #
  # --- eest_zkevm files with failures ---
  #
  # Witness codes mismatch -> codes optimisation: implemented in
  # https://github.com/status-im/nimbus-eth1/pull/4099
  "witness_codes_create_same_hash_then_read.json",

  # No fail yet as we don't check/use public keys. We could check them easily
  # but the better way is to use them as optimization and check automatically
  # that way.
  "stateless_input_invalid_public_key_is_rejected.json",

  # cases of missing code in witness, which we currently don't check for
  "validation_codes_missing_delegated_code_on_insufficient_balance_call.json",
  "validation_codes_missing_sender_delegation_marker.json",
  "validation_codes_missing_redelegation_old_marker.json",
  "validation_codes_missing_external_code_read_target.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  statelessEnabled = true,
  parallelEnabled = false
)
