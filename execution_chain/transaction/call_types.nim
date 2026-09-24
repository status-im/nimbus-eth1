# Nimbus
# Copyright (c) 2024-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  stint,
  results,
  eth/common/transactions,
  eth/common/addresses,
  eth/common/receipts,
  ../common/hardforks,
  ../evm/types,
  ../evm/internals,
  ../core/[eip7702, eip8037]

export types

type
  # Standard call parameters.
  CallParams* = object
    vmState*:   BaseVMState             # Chain, database, state, block, fork.
    gasPrice*:  GasInt                  # Gas price for this tx.
    sender*:    addresses.Address       # Sender account.
    isCreate*:  bool                    # True if this is a contract creation.
    tx*:        ptr Transaction
    intrinsic*: IntrinsicGas

  # Standard call result.
  CallResult* = object of RootObj
    error*:           string            # Something if the call failed.
    gasUsed*:         GasInt            # Gas used by the tx.
    contractAddress*: addresses.Address # Created account (when `isCreate`).
    output*:          seq[byte]         # Output data.

  DebugCallResult* = object of CallResult
    stack*:      seq[UInt256]           # EVM stack on return (for test only).
    memory*:     EvmMemory              # EVM memory on return (for test only).
    logEntries*: seq[Log]

  LogResult* = object
    logEntries*: seq[Log]
    gasUsed*: GasInt
    blockExecutionGasUsed*: GasInt
    blockStateGasUsed*: GasInt
    txFee*: UInt256

  OutputResult* = object
    error*:   string
    output*:  seq[byte]

  VoidResult* = object

  IntrinsicGas* = object
    execution*: GasInt
    floorDataGas*: GasInt

func isError*(cr: CallResult): bool =
  cr.error.len > 0

func selfTransfer(tx: Transaction, sender: Address): bool =
  tx.to.isSome and tx.to.value == sender

const
  TOTAL_COST_FLOOR_PER_TOKEN_EIP7623 = 10
  TOTAL_COST_FLOOR_PER_TOKEN_EIP7976 = 16
  TX_VALUE_COST = 6000

func intrinsicGas*(tx: Transaction, hardFork: HardFork, gasLimit: GasInt, sender: Address): IntrinsicGas =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation).
  let
    fork = ToEVMFork[hardFork]

  var
    executionGas = if hardFork >= Amsterdam: TX_BASE_COST_2780
                   else: TX_BASE_COST
    floorDataGas = executionGas
    tokens = 0
    accessListBytes = 0
    recipientExecutionGas = 0

  # EIP-2 (Homestead) extra intrinsic gas for contract creations.
  if tx.contractCreation:
    if hardFork >= Amsterdam:
      recipientExecutionGas += gasFees[fork][GasTXCreate]
    else:
      executionGas += gasFees[fork][GasTXCreate]
    if hardFork >= Shanghai:
      executionGas += (gasFees[fork][GasInitcodeWord] * tx.payload.len.wordCount)
  elif not tx.selfTransfer(sender):
    if hardFork >= Amsterdam:
      recipientExecutionGas += COLD_ACCOUNT_ACCESS_8038
      if tx.value.isZero.not:
        recipientExecutionGas += TX_VALUE_COST

  # Input data cost, reduced in EIP-2028 (Istanbul).
  let
    gasZero    = gasFees[fork][GasTXDataZero]
    gasNonZero = gasFees[fork][GasTXDataNonZero]
    byteZeroToken = if hardFork >= Amsterdam: 4 else: 1

  for b in tx.payload:
    if b == 0:
      executionGas += gasZero
      tokens += byteZeroToken
    else:
      executionGas += gasNonZero
      tokens += 4

  # EIP-2930 (Berlin) intrinsic gas for transaction access list.
  if hardFork >= Berlin:
    if hardFork >= Amsterdam:
      for account in tx.accessList:
        executionGas += ACCESS_LIST_ADDRESS_COST_8038
        executionGas += account.storageKeys.len * ACCESS_LIST_STORAGE_KEY_COST_8038
        # Total byte count of addresses(20 bytes each) and storage keys (32 bytes each) in the access list.
        accessListBytes += 20 + account.storageKeys.len * 32
    else:
      for account in tx.accessList:
        executionGas += ACCESS_LIST_ADDRESS_COST_2930
        executionGas += account.storageKeys.len * ACCESS_LIST_STORAGE_KEY_COST_2930
        # Total byte count of addresses(20 bytes each) and storage keys (32 bytes each) in the access list.
        accessListBytes += 20 + account.storageKeys.len * 32

  if hardFork >= Prague:
    if hardFork >= Amsterdam:
      executionGas += recipientExecutionGas
      floorDataGas += recipientExecutionGas
      executionGas += EXECUTION_PER_AUTH_BASE_COST * tx.authorizationList.len
      # EIP-7981: Increase Access List Cost
      let floorTokensInAccessList = accessListBytes * 4
      tokens += floorTokensInAccessList
      executionGas += TOTAL_COST_FLOOR_PER_TOKEN_EIP7976 * floorTokensInAccessList
      floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN_EIP7976
    else:
      executionGas += tx.authorizationList.len * PER_EMPTY_ACCOUNT_COST
      floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN_EIP7623

  IntrinsicGas(
    execution: executionGas.GasInt,
    floorDataGas: floorDataGas.GasInt,
  )
