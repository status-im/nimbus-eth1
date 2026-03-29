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
  # Failed ones for eest_develop:
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
  "extCodeHashDELEGATECALL.json",
  "extCodeHashCALL.json",
  "extCodeHashDynamicArgument.json",
  "extCodeHashSTATICCALL.json",
  "extCodeHashInInitCode.json",
  "extCodeHashMaxCodeSize.json",
  "extCodeHashCALLCODE.json",
  # Failed ones for eest_zkevm:
  "precompile_warming.json", # stateRoot mismatch
  "extcodehash_dynamic_argument.json", # gasUsed mismatch
  "extcodehash_in_init_code.json", # gasUsed mismatch
  "extcodehash_via_call.json", # gasUsed mismatch
  "extcodehash_max_code_size.json", # gasUsed mismatch
  "varying_calldata_costs.json", # Witness state mismatch
  "bal_7002_partial_sweep.json", # Aristo DelVidStaleVtx
  "bal_extcodesize_and_oog.json", # Witness codes mismatch
  "bal_account_access_target.json", # Witness codes mismatch
  "bal_aborted_account_access.json", # Witness codes mismatch
  "witness_codes_extcodesize_cold_gas_boundary.json", # Witness codes mismatch
  "witness_codes_extcodesize.json", # Witness codes mismatch
  "witness_state_block_diff_delete_insert_before_delete_order.json", # Aristo DelVidStaleVtx
  "witness_codes_delegated_eoa_insufficient_balance.json", # blockAccessListHash mismatch
  "witness_codes_extcode_delegated_eoa.json", # Witness codes mismatch
  "witness_state_sstore_delete_branch_collapse_adds_auxiliary_node.json", # Aristo DelVidStaleVtx
  "witness_headers_blockhash_boundary.json", # Witness state mismatch
  "witness_headers_multiple_blockhash_max_wins.json", # Witness headers mismatch
  "witness_headers_blockhash_at_offset.json", # Witness headers mismatch
  "witness_headers_blockhash_in_reverted_tx.json", # Witness headers mismatch
  "witness_codes_create_same_hash_then_read.json", # Witness codes mismatch
  "create_and_destroy_multiple_contracts_same_tx.json", # Aristo DelVidStaleVtx
  "consolidation_requests.json", # Witness state mismatch
  "withdrawal_requests.json", # Witness state mismatch
  "block_hashes_history.json", # Witness state mismatch
  "genesis_hash_available.json", # Witness state mismatch
  "scenarios.json", # mixed witness/stateRoot/assertion failures
  "multiple_withdrawals_same_address.json", # Witness state mismatch
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
