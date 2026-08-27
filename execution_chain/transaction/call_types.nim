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
    frames*:       seq[TransactionFrame]# EIP-8141
    signatures*:   seq[FrameSignature]  # EIP-8141

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

template isCreate(tx: Transaction): bool =
  tx.contractCreation

template input(tx: Transaction): auto =
  tx.payload

func isError*(cr: CallResult): bool =
  cr.error.len > 0

func selfTransfer(call: CallParams, sender: Address): bool =
  call.to == sender

func selfTransfer(tx: Transaction, sender: Address): bool =
  tx.to.isSome and tx.to.value == sender

const
  TOTAL_COST_FLOOR_PER_TOKEN_EIP7623 = 10
  TOTAL_COST_FLOOR_PER_TOKEN_EIP7976 = 16
  TX_VALUE_COST = 6000

const
  SCHEME_ARBITRARY* = 0x0
  SCHEME_SECP256K1* = 0x1
  SCHEME_P256*      = 0x2

const
  FRAME_SIGNATURE_SCHEME_SECP256K1 = 2800
  FRAME_SIGNATURE_SCHEME_P256      = 6700
  FRAME_SIGNATURE_SCHEME_ARBITRARY = 100

const
  TX_DATA_TOKEN_STANDARD = 4
  TX_FRAME_INTRINSIC = TX_BASE_COST_2780
  TX_PER_FRAME = 475
  TX_DATA_TOKEN_FLOOR = 16

func signatureVerificationGas(sig: FrameSignature): GasInt =
  if sig.scheme == SCHEME_SECP256K1:
    return FRAME_SIGNATURE_SCHEME_SECP256K1

  if sig.scheme == SCHEME_P256:
    return FRAME_SIGNATURE_SCHEME_P256

  if sig.scheme == SCHEME_ARBITRARY:
    return FRAME_SIGNATURE_SCHEME_ARBITRARY

func countTokensInData(data: openArray[byte]): int =
  # Count the data tokens in arbitrary input bytes.
  # Zero bytes count as 1 token; non-zero bytes count as 4 tokens.
  var
    numZeros = 0

  for x in data:
    if x == 0:
      inc numZeros

  let
    numNonZeros = data.len - numZeros

  numZeros + numNonZeros * 4

func frameTransactionIntrinsicCost*(call: CallParams | Transaction): IntrinsicGas =
  var
    tokens = 0
    dataLength = 0
    valueTransferGas = 0.GasInt

  for frame in call.frames:
    tokens += countTokensInData(frame.data)
    dataLength += frame.data.len
    if frame.value.isZero.not and
       frame.target.isSome and
       frame.target != call.sender:
      valueTransferGas += TX_VALUE_COST

  var
    signatureGas = 0.GasInt

  for sig in call.signatures:
    signatureGas += signatureVerificationGas(sig)
    tokens += countTokensInData(sig.signer)
    tokens += countTokensInData(sig.msg)
    tokens += countTokensInData(sig.signature)
    dataLength += sig.signer.len
    dataLength += sig.msg.len
    dataLength += sig.signature.len

  # EIP-7976 floor tokens: all charged bytes count uniformly.
  let
    floorTokens = dataLength * TX_DATA_TOKEN_STANDARD
    baseExecutionGas = TX_FRAME_INTRINSIC +
      call.frames.len * TX_PER_FRAME +
      signatureGas + valueTransferGas

  IntrinsicGas(
    execution: baseExecutionGas + tokens * TX_DATA_TOKEN_STANDARD,
    floorDataGas: baseExecutionGas + floorTokens * TX_DATA_TOKEN_FLOOR
  )

func intrinsicGas*(call: CallParams | Transaction, hardFork: HardFork, gasLimit: GasInt, sender: Address): IntrinsicGas =
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
  if call.isCreate:
    if hardFork >= Amsterdam:
      recipientExecutionGas += gasFees[fork][GasTXCreate]
    else:
      executionGas += gasFees[fork][GasTXCreate]
    if hardFork >= Shanghai:
      executionGas += (gasFees[fork][GasInitcodeWord] * call.input.len.wordCount)
  elif not call.selfTransfer(sender):
    if hardFork >= Amsterdam:
      recipientExecutionGas += COLD_ACCOUNT_ACCESS_8038
      if call.value.isZero.not:
        recipientExecutionGas += TX_VALUE_COST

  # Input data cost, reduced in EIP-2028 (Istanbul).
  let
    gasZero    = gasFees[fork][GasTXDataZero]
    gasNonZero = gasFees[fork][GasTXDataNonZero]
    byteZeroToken = if hardFork >= Amsterdam: 4 else: 1

  for b in call.input:
    if b == 0:
      executionGas += gasZero
      tokens += byteZeroToken
    else:
      executionGas += gasNonZero
      tokens += 4

  # EIP-2930 (Berlin) intrinsic gas for transaction access list.
  if hardFork >= Berlin:
    if hardFork >= Amsterdam:
      for account in call.accessList:
        executionGas += ACCESS_LIST_ADDRESS_COST_8038
        executionGas += account.storageKeys.len * ACCESS_LIST_STORAGE_KEY_COST_8038
        # Total byte count of addresses(20 bytes each) and storage keys (32 bytes each) in the access list.
        accessListBytes += 20 + account.storageKeys.len * 32
    else:
      for account in call.accessList:
        executionGas += ACCESS_LIST_ADDRESS_COST_2930
        executionGas += account.storageKeys.len * ACCESS_LIST_STORAGE_KEY_COST_2930
        # Total byte count of addresses(20 bytes each) and storage keys (32 bytes each) in the access list.
        accessListBytes += 20 + account.storageKeys.len * 32

  if hardFork >= Prague:
    if hardFork >= Amsterdam:
      executionGas += recipientExecutionGas
      floorDataGas += recipientExecutionGas
      executionGas += EXECUTION_PER_AUTH_BASE_COST * call.authorizationList.len
      # EIP-7981: Increase Access List Cost
      let floorTokensInAccessList = accessListBytes * 4
      tokens += floorTokensInAccessList
      executionGas += TOTAL_COST_FLOOR_PER_TOKEN_EIP7976 * floorTokensInAccessList
      floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN_EIP7976
    else:
      executionGas += call.authorizationList.len * PER_EMPTY_ACCOUNT_COST
      floorDataGas += tokens * TOTAL_COST_FLOOR_PER_TOKEN_EIP7623

  IntrinsicGas(
    execution: executionGas.GasInt,
    floorDataGas: floorDataGas.GasInt,
  )
