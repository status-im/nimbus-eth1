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
  "tests/fixtures/eest_develop/blockchain_tests/berlin/eip2929_gas_cost_increases/test_precompile_warming.json",
  "tests/fixtures/eest_develop/blockchain_tests/frontier/opcodes/test_genesis_hash_available.json",
  "tests/fixtures/eest_develop/blockchain_tests/frontier/scenarios/test_scenarios.json",
  "tests/fixtures/eest_develop/blockchain_tests/frontier/validation/test_gas_limit_below_minimum.json",
  "tests/fixtures/eest_develop/blockchain_tests/prague/eip2935_historical_block_hashes_from_state/test_block_hashes_history_at_transition.json",
  "tests/fixtures/eest_develop/blockchain_tests/prague/eip2935_historical_block_hashes_from_state/test_block_hashes_history.json",
  "tests/fixtures/eest_develop/blockchain_tests/prague/eip2935_historical_block_hashes_from_state/test_eip_2935.json",
  "tests/fixtures/eest_develop/blockchain_tests/prague/eip7002_el_triggerable_withdrawals/test_withdrawal_requests.json",
  "tests/fixtures/eest_develop/blockchain_tests/prague/eip7251_consolidations/test_consolidation_requests.json",
  "tests/fixtures/eest_develop/blockchain_tests/shanghai/eip4895_withdrawals/test_large_amount.json",
  "tests/fixtures/eest_develop/blockchain_tests/shanghai/eip4895_withdrawals/test_multiple_withdrawals_same_address.json",
  "tests/fixtures/eest_develop/blockchain_tests/shanghai/eip4895_withdrawals/test_withdrawals_root.json",
  "tests/fixtures/eest_develop/blockchain_tests/stBadOpcode/invalidAddr.json",
  "tests/fixtures/eest_develop/blockchain_tests/stCreate2/CREATE2_HighNonceDelegatecall.json",
  "tests/fixtures/eest_develop/blockchain_tests/stEIP1559/baseFeeDiffPlaces.json",
  "tests/fixtures/eest_develop/blockchain_tests/stEIP1559/gasPriceDiffPlaces.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashCALLCODE.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashCALL.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashDELEGATECALL.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashDynamicArgument.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashInInitCode.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashMaxCodeSize.json",
  "tests/fixtures/eest_develop/blockchain_tests/stExtCodeHash/extCodeHashSTATICCALL.json",
  "tests/fixtures/eest_develop/blockchain_tests/stStackTests/underflowTest.json",
  "tests/fixtures/eest_develop/blockchain_tests/stStaticFlagEnabled/CallcodeToPrecompileFromCalledContract.json",
  "tests/fixtures/eest_develop/blockchain_tests/stStaticFlagEnabled/CallWithNOTZeroValueToPrecompileFromCalledContract.json",
  "tests/fixtures/eest_develop/blockchain_tests/stStaticFlagEnabled/CallWithZeroValueToPrecompileFromCalledContract.json",
  "tests/fixtures/eest_develop/blockchain_tests/stStaticFlagEnabled/DelegatecallToPrecompileFromCalledContract.json",
  "tests/fixtures/eest_develop/blockchain_tests/stTransactionTest/StoreClearsAndInternalCallStoreClearsOOG.json",
  "tests/fixtures/eest_develop/blockchain_tests/stWalletTest/walletAddOwnerRemovePendingTransaction.json",
  "tests/fixtures/eest_develop/blockchain_tests/stWalletTest/walletChangeOwnerRemovePendingTransaction.json",
  "tests/fixtures/eest_develop/blockchain_tests/stWalletTest/walletChangeRequirementRemovePendingTransaction.json",
  "tests/fixtures/eest_develop/blockchain_tests/stWalletTest/walletConfirm.json",
  "tests/fixtures/eest_develop/blockchain_tests/stWalletTest/walletRemoveOwnerRemovePendingTransaction.json",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType,
  statelessEnabled = true
)
