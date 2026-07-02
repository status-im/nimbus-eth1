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
  # Witness codes mismatch -> codes optimisation: implemented in
  # https://github.com/status-im/nimbus-eth1/pull/4099
  "witness_codes_create_same_hash_then_read.json",

  # related to for_bpo2toamsterdamattime15k
  "precompile_warming.json",
  "call_value_cost_at_transition.json",
  "cold_account_access_at_transition.json",
  "create_base_cost_at_transition.json",
  "ext_code_surcharge_at_transition.json",
  "selfdestruct_account_write_at_transition.json",
  "sstore_write_cost_at_transition.json",
  "reservoir_available_after_transition.json",
  "sstore_state_gas_at_transition.json",
  "tx_gas_above_cap_at_transition.json",
  "max_code_size_via_create_fork_transition.json",
  "max_initcode_size_via_create_fork_transition.json",
  "bal_fork_transition_happy_path.json",
  "fork_transition_bal_size_constraint.json",
  "slotnum_at_fork_transition.json",
  "transfer_log_fork_transition.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true,
  parallelEnabled = false
)
