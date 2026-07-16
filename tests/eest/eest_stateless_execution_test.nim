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
  #
  # --- eest_zkevm files with failures ---
  #
  # Witness codes mismatch -> codes optimisation: implemented in
  # https://github.com/status-im/nimbus-eth1/pull/4099
  "witness_codes_create_same_hash_then_read.json",

  # EIP-7997 issue: specs don't implement the fork-transition state change
  # Nimbus and Geth do.
  # See potential fix if specs remain as is:
  # https://github.com/status-im/nimbus-eth1/pull/4480
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

  # The stateless input schema cannot represent EIP-8282 builder requests, so
  # the guest reconstructs an empty requestsHash while execution emits a builder
  # request -> requestsHash mismatch -> false, but 2 of the 25 vectors wrongly
  # expect true. Upstream schema/vector issue, already fixed in upstream
  # tests-zkevm@v0.6.2
  "invalid_multi_type_requests.json",

  # No fail yet as we don't check/use public keys. We could check them easily
  # but the better way is to use them as optimization and check automatically
  # that way.
  "stateless_input_invalid_public_key_is_rejected.json",
  "stateless_input_opposite_y_parity_public_key_is_rejected.json",

  # cases of missing code in witness
  "validation_codes_missing_delegated_code_on_insufficient_balance_call.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  statelessEnabled = true,
  parallelEnabled = false # Stateless features are not supported with parallel enabled
)
