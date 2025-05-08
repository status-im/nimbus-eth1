# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
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
  ../core/eip7702

export types

type
  # Standard call parameters.
  CallParams* = object
    vmState*:      BaseVMState          # Chain, database, state, block, fork.
    origin*:       Opt[addresses.Address] # Default origin is `sender`.
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
    noIntrinsic*:  bool                 # Don't charge intrinsic gas.
    noAccessList*: bool                 # Don't initialise EIP-2929 access list.
    noGasCharge*:  bool                 # Don't charge sender account for gas.
    noRefund*:     bool                 # Don't apply gas refund/burn rule.
    sysCall*:      bool                 # System call or ordinary call

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
    gasUsed*:    GasInt

  OutputResult* = object
    error*:   string
    output*:  seq[byte]

template isCreate(tx: Transaction): bool =
  tx.contractCreation

template input(tx: Transaction): auto =
  tx.payload

func isError*(cr: CallResult): bool =
  cr.error.len > 0

const
  TOTAL_COST_FLOOR_PER_TOKEN = 10

func intrinsicGas*(call: CallParams | Transaction, fork: EVMFork): (GasInt, GasInt) =
  # Compute the baseline gas cost for this transaction.  This is the amount
  # of gas needed to send this transaction (but that is not actually used
  # for computation).
  var
    intrinsicGas = gasFees[fork][GasTransaction]
    floorDataGas = intrinsicGas
    tokens = 0

  # EIP-2 (Homestead) extra intrinsic gas for contract creations.
  if call.isCreate:
    intrinsicGas += gasFees[fork][GasTXCreate]
    if fork >= FkShanghai:
      intrinsicGas += (gasFees[fork][GasInitcodeWord] * call.input.len.wordCount)

  # Input data cost, reduced in EIP-2028 (Istanbul).
  let gasZero    = gasFees[fork][GasTXDataZero]
  let gasNonZero = gasFees[fork][GasTXDataNonZero]
  for b in call.input:
    if b == 0:
      intrinsicGas += gasZero
      tokens += 1
    else:
      intrinsicGas += gasNonZero
      tokens += 4


  # EIP-2930 (Berlin) intrinsic gas for transaction access list.
  if fork >= FkBerlin:
    for account in call.accessList:
      intrinsicGas += ACCESS_LIST_ADDRESS_COST
      intrinsicGas += GasInt(account.storageKeys.len) * ACCESS_LIST_STORAGE_KEY_COST

  if fork >= FkPrague:
    intrinsicGas += call.authorizationList.len * PER_EMPTY_ACCOUNT_COST
    floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN

  return (intrinsicGas.GasInt, floorDataGas.GasInt)
