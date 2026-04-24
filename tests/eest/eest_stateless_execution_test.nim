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
  "invalidAddr.json", # SIGSEGV
  "underflowTest.json", # stateRoot mismatch
  "CREATE2_HighNonceDelegatecall.json", # stateRoot mismatch
  "test_precompile_warming.json", # stateRoot mismatch
  "StoreClearsAndInternalCallStoreClearsOOG.json", # persistStorage assert
  "test_consolidation_requests.json", # persistStorage assert
  "test_withdrawal_requests.json", # persistStorage assert
  "gasPriceDiffPlaces.json", # stateRoot mismatch
  "baseFeeDiffPlaces.json", # stateRoot mismatch
  "test_genesis_hash_available.json", # witness.validateKeys assert
  "test_scenarios.json", # stateRoot mismatch + persist assert
  "test_gas_limit_below_minimum.json", # multiproof assert
  "test_multiple_withdrawals_same_address.json", # multiproof assert
  "test_large_amount.json", # multiproof assert
  "test_withdrawals_root.json", # witness.validateKeys assert
  "CallcodeToPrecompileFromCalledContract.json", # stateRoot mismatch
  "DelegatecallToPrecompileFromCalledContract.json", # stateRoot mismatch
  "CallWithNOTZeroValueToPrecompileFromCalledContract.json", # stateRoot mismatch
  "CallWithZeroValueToPrecompileFromCalledContract.json", # stateRoot mismatch
  "walletAddOwnerRemovePendingTransaction.json", # persistStorage assert
  "walletRemoveOwnerRemovePendingTransaction.json", # persistStorage assert
  "walletChangeOwnerRemovePendingTransaction.json", # persistStorage assert
  "walletConfirm.json", # persistStorage assert
  "walletChangeRequirementRemovePendingTransaction.json", # persistStorage assert
  #
  # --- eest_zkevm files with failures ---
  #
  "varying_calldata_costs.json", # Witness state mismatch
  "bal_7002_partial_sweep.json", # persistStorage assert
  "witness_codes_delegated_eoa_insufficient_balance.json", # blockAccessListHash mismatch
  "witness_codes_create_same_hash_then_read.json", # Witness codes mismatch
  "witness_headers_blockhash_boundary.json", # Witness state mismatch
  "witness_headers_extra_unused_older_ancestor.json", # Witness headers mismatch
  "witness_state_sstore_delete_branch_collapse_adds_auxiliary_node.json", # persistStorage assert
  "witness_state_block_diff_delete_insert_before_delete_order.json", # persistStorage assert
  "create_and_destroy_multiple_contracts_same_tx.json", # persist assert
  "genesis_hash_available.json", # Witness state mismatch
  "scenarios.json", # Witness state mismatch + stateRoot mismatch
  "withdrawal_requests.json", # persistStorage assert + Witness state mismatch
  "consolidation_requests.json", # Witness state mismatch
  "multiple_withdrawals_same_address.json", # Witness state mismatch
  "precompile_warming.json", # stateRoot mismatch
  "return_bounds.json", # Witness state mismatch
  "underflow_test.json", # stateRoot mismatch
  "create2_high_nonce_delegatecall.json", # stateRoot mismatch
  "store_clears_and_internal_call_store_clears_oog.json", # persistStorage assert
  "gas_price_diff_places.json", # stateRoot mismatch
  "base_fee_diff_places.json", # stateRoot mismatch
  "delegatecall_to_precompile_from_called_contract.json", # stateRoot mismatch
  "wallet_add_owner_remove_pending_transaction.json", # persistStorage assert
  "wallet_confirm.json", # persistStorage assert
  "wallet_remove_owner_remove_pending_transaction.json", # persistStorage assert
  "wallet_change_owner_remove_pending_transaction.json", # persistStorage assert
  "wallet_change_requirement_remove_pending_transaction.json", # persistStorage assert
  "callcode_to_precompile_from_called_contract.json", # stateRoot mismatch
  "validation_codes_missing_delegated_code_on_insufficient_balance_call.json", # blockAccessListHash mismatch
  "validation_state_missing_delete_auxiliary_node.json", # persistStorage assert
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
