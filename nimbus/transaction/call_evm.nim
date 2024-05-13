# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[options],
  chronicles,
  chronos,
  eth/common/eth_types_rlp,
  ".."/[vm_types, vm_state, vm_gas_costs],
  ../db/ledger,
  ../common/common,
  ../rpc/params,
  ./call_common

export
  call_common

proc rpcCallEvm*(args: TransactionArgs, header: common.BlockHeader, com: CommonRef): CallResult
    {.gcsafe, raises: [CatchableError].} =
  const globalGasCap = 0 # TODO: globalGasCap should configurable by user
  let topHeader = common.BlockHeader(
    parentHash: header.blockHash,
    timestamp:  EthTime.now(),
    gasLimit:   0.GasInt,          ## ???
    fee:        UInt256.none())    ## ???
  let vmState = BaseVMState.new(topHeader, com)
  let params  = toCallParams(vmState, args, globalGasCap, header.fee)

  var dbTx = com.db.beginTransaction()
  defer: dbTx.dispose() # always dispose state changes

  runComputation(params)

proc rpcCallEvm*(args: TransactionArgs,
                 header: common.BlockHeader,
                 com: CommonRef,
                 vmState: BaseVMState): CallResult
    {.gcsafe, raises: [CatchableError].} =
  const globalGasCap = 0 # TODO: globalGasCap should configurable by user
  let params  = toCallParams(vmState, args, globalGasCap, header.fee)

  var dbTx = com.db.beginTransaction()
  defer: dbTx.dispose() # always dispose state changes

  runComputation(params)

proc rpcEstimateGas*(args: TransactionArgs,
                     header: common.BlockHeader,
                     com: CommonRef, gasCap: GasInt): GasInt
    {.gcsafe, raises: [CatchableError].} =
  # Binary search the gas requirement, as it may be higher than the amount used
  let topHeader = common.BlockHeader(
    parentHash: header.blockHash,
    timestamp:  EthTime.now(),
    gasLimit:   0.GasInt,          ## ???
    fee:        UInt256.none())    ## ???
  let vmState = BaseVMState.new(topHeader, com)
  let fork    = vmState.determineFork
  let txGas   = gasFees[fork][GasTransaction] # txGas always 21000, use constants?
  var params  = toCallParams(vmState, args, gasCap, header.fee)

  var
    lo : GasInt = txGas - 1
    hi : GasInt = GasInt args.gas.get(0.Quantity)
    cap: GasInt

  var dbTx = com.db.beginTransaction()
  defer: dbTx.dispose() # always dispose state changes

  # Determine the highest gas limit can be used during the estimation.
  if hi < txGas:
    # block's gasLimit act as the gas ceiling
    hi = header.gasLimit

  # Normalize the max fee per gas the call is willing to spend.
  var feeCap = GasInt args.gasPrice.get(0.Quantity)
  if args.gasPrice.isSome and
    (args.maxFeePerGas.isSome or args.maxPriorityFeePerGas.isSome):
    raise newException(ValueError,
      "both gasPrice and (maxFeePerGas or maxPriorityFeePerGas) specified")
  elif args.maxFeePerGas.isSome:
    feeCap = GasInt args.maxFeePerGas.get

  # Recap the highest gas limit with account's available balance.
  if feeCap > 0:
    if args.source.isNone:
      raise newException(ValueError, "`from` can't be null")

    let balance = vmState.readOnlyStateDB.getBalance(ethAddr args.source.get)
    var available = balance
    if args.value.isSome:
      let value = args.value.get
      if value > available:
        raise newException(ValueError, "insufficient funds for transfer")
      available -= value

    let allowance = available div feeCap.u256
    # If the allowance is larger than maximum GasInt, skip checking
    if allowance < high(GasInt).u256 and hi > allowance.truncate(GasInt):
      let transfer = args.value.get(0.u256)
      warn "Gas estimation capped by limited funds", original=hi, balance,
        sent=transfer, maxFeePerGas=feeCap, fundable=allowance
      hi = allowance.truncate(GasInt)

  # Recap the highest gas allowance with specified gasCap.
  if gasCap != 0 and hi > gasCap:
    warn "Caller gas above allowance, capping", requested=hi, cap=gasCap
    hi = gasCap

  cap = hi
  let intrinsicGas = intrinsicGas(params, vmState)

  # Create a helper to check if a gas allowance results in an executable transaction
  proc executable(gasLimit: GasInt): bool
      {.gcsafe, raises: [CatchableError].} =
    if intrinsicGas > gasLimit:
      # Special case, raise gas limit
      return true

    params.gasLimit = gasLimit
    # TODO: bail out on consensus error similar to validateTransaction
    runComputation(params).isError

  # Execute the binary search and hone in on an executable gas limit
  while lo+1 < hi:
    let mid = (hi + lo) div 2
    let failed = executable(mid)
    if failed:
      lo = mid
    else:
      hi = mid

  # Reject the transaction as invalid if it still fails at the highest allowance
  if hi == cap:
    let failed = executable(hi)
    if failed:
      # TODO: provide more descriptive EVM error beside out of gas
      # e.g. revert and other EVM errors
      raise newException(ValueError, "gas required exceeds allowance " & $cap)

  hi

proc callParamsForTx(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: EVMFork): CallParams =
  # Is there a nice idiom for this kind of thing? Should I
  # just be writing this as a bunch of assignment statements?
  result = CallParams(
    vmState:      vmState,
    forkOverride: some(fork),
    gasPrice:     tx.payload.max_fee_per_gas.truncate(int64).GasInt,
    gasLimit:     tx.payload.gas.int64,
    sender:       sender,
    to:           tx.payload.to.get(default(EthAddress)),
    isCreate:     tx.contractCreation,
    value:        tx.payload.value,
    input:        distinctBase(tx.payload.input)
  )
  if tx.payload.access_list.isSome:
    result.accessList = tx.payload.access_list.unsafeGet

  if tx.payload.blob_versioned_hashes.isSome:
    result.versionedHashes =
      distinctBase(tx.payload.blob_versioned_hashes.unsafeGet)

proc callParamsForTest(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: EVMFork): CallParams =
  result = CallParams(
    vmState:      vmState,
    forkOverride: some(fork),
    gasPrice:     tx.payload.max_fee_per_gas.truncate(int64).GasInt,
    gasLimit:     tx.payload.gas.int64,
    sender:       sender,
    to:           tx.payload.to.get(default(EthAddress)),
    isCreate:     tx.contractCreation,
    value:        tx.payload.value,
    input:        distinctBase(tx.payload.input),

    noIntrinsic:  true, # Don't charge intrinsic gas.
    noRefund:     true, # Don't apply gas refund/burn rule.
  )
  if tx.payload.access_list.isSome:
    result.accessList = tx.payload.access_list.unsafeGet

  if tx.payload.blob_versioned_hashes.isSome:
    result.versionedHashes =
      distinctBase(tx.payload.blob_versioned_hashes.unsafeGet)

proc txCallEvm*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: EVMFork): GasInt
    {.gcsafe, raises: [CatchableError].} =
  let call = callParamsForTx(tx, sender, vmState, fork)
  return runComputation(call).gasUsed

proc testCallEvm*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: EVMFork): CallResult
    {.gcsafe, raises: [CatchableError].} =
  let call = callParamsForTest(tx, sender, vmState, fork)
  runComputation(call)

# FIXME-duplicatedForAsync
proc asyncTestCallEvm*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: EVMFork): Future[CallResult] {.async.} =
  let call = callParamsForTest(tx, sender, vmState, fork)
  return await asyncRunComputation(call)
