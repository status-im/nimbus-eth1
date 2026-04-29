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
  results,
  eth/common/transactions,
  eth/common/addresses,
  eth/common/receipts,
  ../common/evmforks,
  ../evm/types,
  ../evm/internals,
  ../core/[eip7702, eip8037]

export types

type
  # Standard call parameters.
  CallParams* = object
    vmState*:      BaseVMState          # Chain, database, state, block, fork.
    gasPrice*:     GasInt               # Gas price for this call.
    gasLimit*:     GasInt               # Maximum gas available for this call.
    sender*:       addresses.Address    # Sender account.
    to*:           addresses.Address    # Recipient (ignored when `isCreate`).
    isCreate*:     bool                 # True if this is a contract creation.
    value*:        UInt256              # Value sent from sender to recipient.
    input*:        seq[byte]            # Input data.
    accessList*:   AccessList           # EIP-2930 (Berlin) tx access list.
    versionedHashes*: seq[VersionedHash]   # EIP-4844 (Cancun) blob versioned hashes
    authorizationList*: seq[Authorization] # EIP-7702 (Prague) authorization list
    intrinsic*:    IntrinsicGas

  # Standard call result.
  CallResult* = object of RootObj
    error*:           string            # Something if the call failed.
    gasUsed*:         GasInt            # Gas used by the call.
    contractAddress*: addresses.Address # Created account (when `isCreate`).
    output*:          seq[byte]         # Output data.

  DebugCallResult* = object of CallResult
    stack*:           seq[UInt256]      # EVM stack on return (for test only).
    memory*:          EvmMemory         # EVM memory on return (for test only).
    logEntries*: seq[Log]

  LogResult* = object
    logEntries*: seq[Log]
    gasUsed*: GasInt
    blockRegularGasUsed*: GasInt
    blockStateGasUsed*: GasInt

  OutputResult* = object
    error*:   string
    output*:  seq[byte]

  IntrinsicGas* = object
    regular*: GasInt
    state*: GasInt
    floorDataGas*: GasInt

template isCreate(tx: Transaction): bool =
  tx.contractCreation

template input(tx: Transaction): auto =
  tx.payload

func isError*(cr: CallResult): bool =
  cr.error.len > 0

const
  TOTAL_COST_FLOOR_PER_TOKEN_EIP7623 = 10
  TOTAL_COST_FLOOR_PER_TOKEN_EIP7976 = 16

func intrinsicGas*(call: CallParams | Transaction, fork: EVMFork, gasLimit: GasInt): IntrinsicGas =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation).
  var
    regularGas = TX_BASE_COST
    stateGas = 0.GasInt
    floorDataGas = regularGas
    tokens = 0
    accessListBytes = 0

  # EIP-2 (Homestead) extra intrinsic gas for contract creations.
  if call.isCreate:
    if fork >= FkAmsterdam:
      stateGas += CREATE_ACCOUNT_STATE_GAS

    regularGas += gasFees[fork][GasTXCreate]
    if fork >= FkShanghai:
      regularGas += (gasFees[fork][GasInitcodeWord] * call.input.len.wordCount)

  # Input data cost, reduced in EIP-2028 (Istanbul).
  let
    gasZero    = gasFees[fork][GasTXDataZero]
    gasNonZero = gasFees[fork][GasTXDataNonZero]
    byteZeroToken = if fork >= FkAmsterdam: 4 else: 1

  for b in call.input:
    if b == 0:
      regularGas += gasZero
      tokens += byteZeroToken
    else:
      regularGas += gasNonZero
      tokens += 4

  # EIP-2930 (Berlin) intrinsic gas for transaction access list.
  if fork >= FkBerlin:
    for account in call.accessList:
      regularGas += ACCESS_LIST_ADDRESS_COST
      regularGas += account.storageKeys.len * ACCESS_LIST_STORAGE_KEY_COST
      # Total byte count of addresses(20 bytes each) and storage keys (32 bytes each) in the access list.
      accessListBytes += 20 + account.storageKeys.len * 32

  if fork >= FkPrague:
    if fork >= FkAmsterdam:
      regularGas += REGULAR_PER_AUTH_BASE_COST * call.authorizationList.len
      # EIP-7981: Increase Access List Cost
      let floorTokensInAccessList = accessListBytes * 4
      tokens += floorTokensInAccessList
      regularGas += TOTAL_COST_FLOOR_PER_TOKEN_EIP7976 * floorTokensInAccessList
      stateGas += (STATE_BYTES_PER_NEW_ACCOUNT + STATE_BYTES_PER_AUTH_BASE) * COST_PER_STATE_BYTE * GasInt(call.authorizationList.len)
      floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN_EIP7976
    else:
      regularGas += call.authorizationList.len * PER_EMPTY_ACCOUNT_COST
      floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN_EIP7623

  IntrinsicGas(
    regular: regularGas.GasInt,
    state: stateGas,
    floorDataGas: floorDataGas.GasInt,
  )
