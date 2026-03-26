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
    "eest_develop"
  ]

const skipFiles = [
  # Currently skipped as still failing with statelessEnabled = true
  # Once all of these pass we could simply run eest_blockchain_test.nim
  # with statelessEnabled = true and remove this test file.
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
  "extCodeHashCALLCODE.json"
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
