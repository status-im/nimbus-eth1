# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  results,
  chronicles,
  eth/common/[addresses, headers],
  web3/eth_api_types,
  ../transaction,
  ../transaction/call_common,
  ../evm/types,
  ../constants

const
  ZeroAddr = ZERO_ADDRESS

func sender*(args: TransactionArgs): Address =
  args.source.get(ZeroAddr)

func txType(n: TransactionArgs): TxType =
  if n.authorizationList.isSome:
    return TxEip7702
  if n.blobVersionedHashes.isSome:
    return TxEip4844
  if n.maxFeePerGas.isSome or n.maxPriorityFeePerGas.isSome:
    return TxEip1559
  if n.accessList.isSome:
    return TxEip2930
  TxLegacy

proc toTransaction*(vmState: BaseVMState,
                    args: TransactionArgs,
                    globalGasCap: GasInt,
                    header: Header): Result[Transaction, string] =

  # Reject invalid combinations of pre- and post-1559 fee styles
  if args.gasPrice.isSome and
    (args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome):
    return err("Invalid combinations of pre and post 1559 fee styles")

  # Set default gas & gas price if none were set
  var gasLimit = globalGasCap
  if gasLimit == 0:
    gasLimit = high(uint64) div 2

  if args.gas.isSome:
    gasLimit = GasInt args.gas.get()

  if globalGasCap != 0 and globalGasCap < gasLimit:
    warn "Caller gas above allowance, capping",
      requested = gasLimit,
      cap = globalGasCap,
      gasLimit = globalGasCap

  template versionedHashes(args: TransactionArgs): seq[VersionedHash] =
    if args.blobVersionedHashes.isSome:
      args.blobVersionedHashes.get
    else:
      @[]

  ok(Transaction(
    txType:               txType(args),
    chainId:              args.chainId.get(0.u256),
    nonce:                args.nonce.get(0.Quantity).AccountNonce,
    gasPrice:             args.gasPrice.get(0.Quantity).GasInt,
    maxPriorityFeePerGas: args.maxPriorityFeePerGas.get(0.Quantity).GasInt,
    maxFeePerGas:         args.maxFeePerGas.get(0.Quantity).GasInt,
    gasLimit:             gasLimit,
    to:                   args.to,
    value:                args.value.get(0.u256),
    payload:              args.payload(),
    accessList:           args.accessList.get(@[]),
    maxFeePerBlobGas:     args.maxFeePerBlobGas.get(0.u256),
    versionedHashes:      args.versionedHashes,
    authorizationList:    args.authorizationList.get(@[]),
  ))

{.pop.}
