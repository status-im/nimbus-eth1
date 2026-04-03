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
  # --- eest_develop files with failures ---
  #
  "invalidAddr.json",
  "underflowTest.json",
  "CREATE2_HighNonceDelegatecall.json",
  "test_precompile_warming.json",
  "StoreClearsAndInternalCallStoreClearsOOG.json",
  "test_consolidation_requests.json",
  "test_withdrawal_requests.json",
  "test_eip_2935.json",
  "test_block_hashes_history_at_transition.json",
  "test_block_hashes_history.json",
  "gasPriceDiffPlaces.json",
  "baseFeeDiffPlaces.json",
  "test_genesis_hash_available.json",
  "test_scenarios.json",
  "test_gas_limit_below_minimum.json",
  "test_multiple_withdrawals_same_address.json",
  "test_large_amount.json",
  "test_withdrawals_root.json",
  "CallcodeToPrecompileFromCalledContract.json",
  "DelegatecallToPrecompileFromCalledContract.json",
  "CallWithNOTZeroValueToPrecompileFromCalledContract.json",
  "CallWithZeroValueToPrecompileFromCalledContract.json",
  "walletAddOwnerRemovePendingTransaction.json",
  "walletRemoveOwnerRemovePendingTransaction.json",
  "walletChangeOwnerRemovePendingTransaction.json",
  "walletConfirm.json",
  "walletChangeRequirementRemovePendingTransaction.json",
  #
  # --- eest_zkevm files with failures ---
  #
  "varying_calldata_costs.json",
  "bal_7002_partial_sweep.json",
  "witness_codes_delegated_eoa_insufficient_balance.json",
  "witness_headers_blockhash_at_offset.json",
  "witness_headers_blockhash_boundary.json",
  "witness_headers_blockhash_in_reverted_tx.json",
  "witness_headers_multiple_blockhash_max_wins.json",
  "witness_state_sstore_delete_branch_collapse_adds_auxiliary_node.json",
  "witness_state_block_diff_delete_insert_before_delete_order.json",
  "create_and_destroy_multiple_contracts_same_tx.json",
  "genesis_hash_available.json",
  "scenarios.json",
  "block_hashes_history.json",
  "withdrawal_requests.json",
  "consolidation_requests.json",
  "multiple_withdrawals_same_address.json",
  "precompile_warming.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
