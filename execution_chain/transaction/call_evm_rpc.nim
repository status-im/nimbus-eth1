# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  eth/common/eth_types_rlp,
  ../evm/[types, state, internals],
  ../db/ledger,
  ../transaction,
  ../evm/evm_errors,
  ../rpc/params,
  ./call_common,
  web3/eth_api_types,
  ../common/common

export
  call_common

proc rpcCallEvm*(args: TransactionArgs,
                 header: Header,
                 headerHash: Hash32,
                 com: CommonRef,
                 parentFrame: CoreDbTxRef,
                 globalGasCap = 0.GasInt): EvmResult[CallResult] =
  # TODO: globalGasCap should configurable by user

  let topHeader = Header(
    parentHash: headerHash,
    timestamp:  EthTime.now(),
    gasLimit:   0.GasInt,              ## ???
    baseFeePerGas: Opt.none UInt256, ## ???
  )

  let txFrame = parentFrame.txFrameBegin()
  defer: txFrame.dispose() # always dispose state changes

  let vmState = BaseVMState.new(header, topHeader, com, txFrame)
  let params  = ? toCallParams(vmState, args, globalGasCap, header.baseFeePerGas)

  ok(runComputation(params, CallResult))

proc rpcCallEvm*(args: TransactionArgs,
                 header: Header,
                 vmState: BaseVMState,
                 globalGasCap = 0.GasInt): EvmResult[CallResult] =
  # TODO: globalGasCap should configurable by user
  let params  = ? toCallParams(vmState, args, globalGasCap, header.baseFeePerGas)
  ok(runComputation(params, CallResult))

proc rpcEstimateGas*(args: TransactionArgs,
                     header: Header,
                     vmState: BaseVMState,
                     gasCap: GasInt): Result[GasInt, (EvmErrorObj, OutputResult)] =
  # Binary search the gas requirement, as it may be higher than the amount used
  # TODO: rpcEstimateGas does not seem to add gas cost for EIP-7702
  # authorization, see test case estimate-with-eip-7702.io of
  # execution-apis tests
  let fork    = vmState.fork
  let txGas   = GasInt gasFees[fork][GasTransaction] # txGas always 21000, use constants?
  var params  = toCallParams(vmState, args, gasCap, header.baseFeePerGas).valueOr:
    return err((evmErr(EvmInvalidParam), OutputResult()))

  var
    lo : GasInt = txGas - 1
    hi : GasInt = GasInt args.gas.get(0.Quantity)

  # Determine the highest gas limit can be used during the estimation.
  if hi < txGas:
    # block's gasLimit act as the gas ceiling
    hi = header.gasLimit

  # Normalize the execution fee per gas used by the estimator.
  if args.gasPrice.isSome and
    (args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome):
    return err((evmErr(EvmInvalidParam), OutputResult()))
  let feeCap = params.gasPrice

  # Recap the highest gas limit with account's available balance.
  if feeCap > 0:
    if args.source.isNone:
      return err((evmErr(EvmInvalidParam), OutputResult()))

    let balance = vmState.readOnlyLedger.getBalance(args.source.get)
    var available = balance
    if args.value.isSome:
      let value = args.value.get
      if value >= available:
        return err((evmErr(EvmInvalidParam), OutputResult()))
      available -= value

    let allowance = available div feeCap.u256
    # If the allowance is larger than maximum GasInt, skip checking
    if allowance < high(GasInt).u256 and hi > allowance.truncate(GasInt):
      let transfer = args.value.get(0.u256)
      warn "Gas estimation capped by limited funds", original=hi, balance,
        sent=transfer, feePerGas=feeCap, fundable=allowance
      hi = allowance.truncate(GasInt)

  # Recap the highest gas allowance with specified gasCap.
  if gasCap != 0 and hi > gasCap:
    warn "Caller gas above allowance, capping", requested=hi, cap=gasCap
    hi = gasCap

  let
    (intrinsicGas, floorDataGas) = intrinsicGas(params, fork)
    minGasLimit = max(intrinsicGas, floorDataGas)

  # Create a helper to check if a gas allowance results in an executable transaction
  proc executable(gasLimit: GasInt): Result[CallResult, OutputResult] =
    if minGasLimit > gasLimit:
      # Special case, raise gas limit
      return err(OutputResult())

    params.gasLimit = gasLimit
    # TODO: bail out on consensus error similar to validateTransaction
    let res = runComputation(params, CallResult)
    if res.error.len > 0:
      err(OutputResult(error: res.error, output: res.output))
    else:
      ok(res)

  # First execute at the highest allowance. If this fails, the tx is invalid for estimation under current constraints.
  let firstRun = executable(hi).valueOr:
    return err((evmErr(EvmInvalidParam), error))

  # Used gas from the unconstrained execution is typically a better lower bound.
  if firstRun.gasUsed > 0:
    lo = max(lo, firstRun.gasUsed - 1)

  # Execute the binary search and hone in on an executable gas limit
  while lo+1 < hi:
    let mid = (hi + lo) div 2
    if executable(mid).isErr:
      lo = mid
    else:
      hi = mid

  ok(hi)

proc rpcEstimateGas*(args: TransactionArgs,
                     header: Header,
                     headerHash: Hash32,
                     com: CommonRef,
                     parentFrame: CoreDbTxRef,
                     gasCap: GasInt): Result[GasInt, (EvmErrorObj, OutputResult)] =
  # Binary search the gas requirement, as it may be higher than the amount used
  let topHeader = Header(
    parentHash: headerHash,
    timestamp:  EthTime.now(),
    gasLimit:   0.GasInt,              ## ???
    baseFeePerGas: Opt.none UInt256,   ## ???
  )

  let txFrame = parentFrame.txFrameBegin()
  defer:
    txFrame.dispose() # always dispose state changes

  let vmState = BaseVMState.new(header, topHeader, com, txFrame)
  rpcEstimateGas(args, header, vmState, gasCap)
