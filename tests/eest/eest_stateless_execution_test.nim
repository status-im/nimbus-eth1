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

  # The test code only support Prague request types, need to add Amsterdam request types
  "invalid_multi_type_requests.json",

  # No fail yet as we don't verify chain_config
  "validation_chain_config_wrong_chain_id_legacy_signature.json",

  # No fail yet as we don't check/use public keys. We could check them easily
  # but the better way is to use them as optimization and check automatically
  # that way.
  "stateless_input_invalid_public_key_is_rejected.json",
  "stateless_input_opposite_y_parity_public_key_is_rejected.json",

  # cases of missing code in witness, which we currently don't check for
  "validation_codes_missing_delegated_code_on_insufficient_balance_call.json",
  "validation_codes_missing_sender_delegation_marker.json",
  "validation_codes_missing_redelegation_old_marker.json",
  "validation_codes_missing_external_code_read_target.json",

  # cases of missing states in witness, which we currently don't check for
  "validation_state_missing_failed_call_target_account_proof_node.json",
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
