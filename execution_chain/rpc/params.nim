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
  chronicles,
  eth/common/[addresses, headers],
  web3/eth_api_types,
  ../transaction,
  ../transaction/call_common,
  ../evm/types,
  ../evm/evm_errors,
  ../constants

const
  ZeroAddr = ZERO_ADDRESS

func sender*(args: TransactionArgs): Address =
  args.source.get(ZeroAddr)

func destination*(args: TransactionArgs): Address =
  args.to.get(ZeroAddr)

proc toCallParams*(vmState: BaseVMState,
                   args: TransactionArgs,
                   globalGasCap: GasInt,
                   header: Header): EvmResult[CallParams] =

  # Reject invalid combinations of pre- and post-1559 fee styles
  if args.gasPrice.isSome and
    (args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome):
    return err(evmErr(EvmInvalidParam))

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

  var gasPrice = GasInt args.gasPrice.get(0.Quantity)
  if header.baseFeePerGas.isSome:
    # A basefee is provided, necessitating EIP-1559-type execution
    let
        feeNormTx = Transaction(
          txType:
            if args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome:
              TxEip1559
            else:
              TxLegacy,
          gasPrice: GasInt args.gasPrice.get(0.Quantity),
          maxPriorityFeePerGas: GasInt args.maxPriorityFeePerGas.get(0.Quantity),
          maxFeePerGas: GasInt args.maxFeePerGas.get(0.Quantity),
        )
        maxPriorityFee = feeNormTx.maxPriorityFeePerGasNorm
        maxFee = feeNormTx.maxFeePerGasNorm

    # Backfill the legacy gasPrice for EVM execution, unless we're all zeroes
    if maxPriorityFee > 0 or maxFee > 0:
      let baseFee = header.baseFeePerGas.value.truncate(GasInt)
      let priorityFee = min(maxPriorityFee, maxFee - baseFee)
      gasPrice = priorityFee + baseFee

  template versionedHashes(args: TransactionArgs): seq[VersionedHash] =
    if args.blobVersionedHashes.isSome:
      args.blobVersionedHashes.get
    else:
      @[]

  var res = CallParams(
    vmState:         vmState,
    sender:          args.sender,
    to:              args.destination,
    isCreate:        args.to.isNone,
    gasLimit:        gasLimit,
    gasPrice:        gasPrice,
    value:           args.value.get(0.u256),
    input:           args.payload(),
    accessList:      args.accessList.get(@[]),
    versionedHashes: args.versionedHashes,
    authorizationList: args.authorizationList.get(@[]),
  )

  res.intrinsic = res.intrinsicGas(vmState.hardFork, header.gasLimit)
  ok(move(res))

{.pop.}
