# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  chronicles,
  ../common/common,
  ../transaction/call_common,
  ../vm_types,
  ../beacon/web3_eth_conv,
  ./rpc_types

export
  web3_eth_conv,
  rpc_types

const
  ZeroAddr = w3Addr ZERO_ADDRESS

func sender*(args: TransactionArgs): EthAddress =
  ethAddr args.source.get(ZeroAddr)

func destination*(args: TransactionArgs): EthAddress =
  ethAddr args.to.get(ZeroAddr)

proc toCallParams*(vmState: BaseVMState, args: TransactionArgs,
                   globalGasCap: GasInt, baseFee: Option[UInt256],
                   forkOverride = none(EVMFork)): CallParams
    {.gcsafe, raises: [ValueError].} =

  # Reject invalid combinations of pre- and post-1559 fee styles
  if args.gasPrice.isSome and
    (args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome):
    raise newException(ValueError,
      "both gasPrice and (maxFeePerGas or maxPriorityFeePerGas) specified")

  # Set default gas & gas price if none were set
  var gasLimit = globalGasCap
  if gasLimit == 0:
    gasLimit = GasInt(high(uint64) div 2)

  if args.gas.isSome:
    gasLimit = GasInt args.gas.get()

  if globalGasCap != 0 and globalGasCap < gasLimit:
    warn "Caller gas above allowance, capping",
      requested = gasLimit,
      cap = globalGasCap,
      gasLimit = globalGasCap

  var gasPrice = GasInt args.gasPrice.get(0.Quantity)
  if baseFee.isSome:
    # A basefee is provided, necessitating EIP-1559-type execution
    let maxPriorityFee = GasInt args.maxPriorityFeePerGas.get(0.Quantity)
    let maxFee = GasInt args.maxFeePerGas.get(0.Quantity)

    # Backfill the legacy gasPrice for EVM execution, unless we're all zeroes
    if maxPriorityFee > 0 or maxFee > 0:
      let baseFee = baseFee.get().truncate(GasInt)
      let priorityFee = min(maxPriorityFee, maxFee - baseFee)
      gasPrice = priorityFee + baseFee

  template versionedHashes(args: TransactionArgs): VersionedHashes =
    if args.blobVersionedHashes.isSome:
      ethHashes args.blobVersionedHashes.get
    else:
      @[]

  CallParams(
    vmState:         vmState,
    forkOverride:    forkOverride,
    sender:          args.sender,
    to:              args.destination,
    isCreate:        args.to.isNone,
    gasLimit:        gasLimit,
    gasPrice:        gasPrice,
    value:           args.value.get(0.u256),
    input:           args.payload(),
    accessList:      ethAccessList args.accessList,
    versionedHashes: args.versionedHashes,
  )

{.pop.}
