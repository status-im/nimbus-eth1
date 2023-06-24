# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[options, times],
  chronicles,
  chronos,
  eth/[common/eth_types_rlp, trie/db],
  ".."/[vm_types, vm_state, vm_gas_costs],
  ../db/accounts_cache,
  ../common/common,
  ./call_common

type
  RpcCallData* = object
    source*        : Option[EthAddress]
    to*            : Option[EthAddress]
    gasLimit*      : Option[GasInt]
    gasPrice*      : Option[GasInt]
    maxFee*        : Option[GasInt]
    maxPriorityFee*: Option[GasInt]
    value*         : Option[UInt256]
    data*          : seq[byte]
    accessList*    : AccessList
    versionedHashes*: VersionedHashes

proc toCallParams(vmState: BaseVMState, cd: RpcCallData,
                  globalGasCap: GasInt, baseFee: Option[UInt256],
                  forkOverride = none(EVMFork)): CallParams
    {.gcsafe, raises: [ValueError].} =

  # Reject invalid combinations of pre- and post-1559 fee styles
  if cd.gasPrice.isSome and (cd.maxFee.isSome or cd.maxPriorityFee.isSome):
    raise newException(ValueError, "both gasPrice and (maxFeePerGas or maxPriorityFeePerGas) specified")

  # Set default gas & gas price if none were set
  var gasLimit = globalGasCap
  if gasLimit == 0:
    gasLimit = GasInt(high(uint64) div 2)

  if cd.gasLimit.isSome:
    gasLimit = cd.gasLimit.get()

  if globalGasCap != 0 and globalGasCap < gasLimit:
    warn "Caller gas above allowance, capping", requested = gasLimit, cap = globalGasCap
    gasLimit = globalGasCap

  var gasPrice = cd.gasPrice.get(0.GasInt)
  if baseFee.isSome:
    # A basefee is provided, necessitating EIP-1559-type execution
    let maxPriorityFee = cd.maxPriorityFee.get(0.GasInt)
    let maxFee = cd.maxFee.get(0.GasInt)

    # Backfill the legacy gasPrice for EVM execution, unless we're all zeroes
    if maxPriorityFee > 0 or maxFee > 0:
      let baseFee = baseFee.get().truncate(GasInt)
      let priorityFee = min(maxPriorityFee, maxFee - baseFee)
      gasPrice = priorityFee + baseFee

  CallParams(
    vmState:      vmState,
    forkOverride: forkOverride,
    sender:       cd.source.get(ZERO_ADDRESS),
    to:           cd.to.get(ZERO_ADDRESS),
    isCreate:     cd.to.isNone,
    gasLimit:     gasLimit,
    gasPrice:     gasPrice,
    value:        cd.value.get(0.u256),
    input:        cd.data,
    accessList:   cd.accessList,
    versionedHashes:cd.versionedHashes
  )

proc rpcCallEvm*(call: RpcCallData, header: BlockHeader, com: CommonRef): CallResult
    {.gcsafe, raises: [CatchableError].} =
  const globalGasCap = 0 # TODO: globalGasCap should configurable by user
  let topHeader = BlockHeader(
    parentHash: header.blockHash,
    timestamp:  getTime().utc.toTime,
    gasLimit:   0.GasInt,          ## ???
    fee:        UInt256.none())    ## ???
  let vmState = BaseVMState.new(topHeader, com)
  let params  = toCallParams(vmState, call, globalGasCap, header.fee)

  var dbTx = com.db.db.beginTransaction()
  defer: dbTx.dispose() # always dispose state changes

  runComputation(params)

proc rpcEstimateGas*(cd: RpcCallData, header: BlockHeader, com: CommonRef, gasCap: GasInt): GasInt
    {.gcsafe, raises: [CatchableError].} =
  # Binary search the gas requirement, as it may be higher than the amount used
  let topHeader = BlockHeader(
    parentHash: header.blockHash,
    timestamp:  getTime().utc.toTime,
    gasLimit:   0.GasInt,          ## ???
    fee:        UInt256.none())    ## ???
  let vmState = BaseVMState.new(topHeader, com)
  let fork    = vmState.determineFork
  let txGas   = gasFees[fork][GasTransaction] # txGas always 21000, use constants?
  var params  = toCallParams(vmState, cd, gasCap, header.fee)

  var
    lo : GasInt = txGas - 1
    hi : GasInt = cd.gasLimit.get(0.GasInt)
    cap: GasInt

  var dbTx = com.db.db.beginTransaction()
  defer: dbTx.dispose() # always dispose state changes

  # Determine the highest gas limit can be used during the estimation.
  if hi < txGas:
    # block's gasLimit act as the gas ceiling
    hi = header.gasLimit

  # Normalize the max fee per gas the call is willing to spend.
  var feeCap = cd.gasPrice.get(0.GasInt)
  if cd.gasPrice.isSome and (cd.maxFee.isSome or cd.maxPriorityFee.isSome):
    raise newException(ValueError, "both gasPrice and (maxFeePerGas or maxPriorityFeePerGas) specified")
  elif cd.maxFee.isSome:
    feeCap = cd.maxFee.get

  # Recap the highest gas limit with account's available balance.
  if feeCap > 0:
    if cd.source.isNone:
      raise newException(ValueError, "`from` can't be null")

    let balance = vmState.readOnlyStateDB.getBalance(cd.source.get)
    var available = balance
    if cd.value.isSome:
      let value = cd.value.get
      if value > available:
        raise newException(ValueError, "insufficient funds for transfer")
      available -= value

    let allowance = available div feeCap.u256
    # If the allowance is larger than maximum GasInt, skip checking
    if allowance < high(GasInt).u256 and hi > allowance.truncate(GasInt):
      let transfer = cd.value.get(0.u256)
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
    gasPrice:     tx.gasPrice,
    gasLimit:     tx.gasLimit,
    sender:       sender,
    to:           tx.destination,
    isCreate:     tx.contractCreation,
    value:        tx.value,
    input:        tx.payload
  )
  if tx.txType > TxLegacy:
    shallowCopy(result.accessList, tx.accessList)

  if tx.txType >= TxEip4844:
    result.versionedHashes = tx.versionedHashes

proc callParamsForTest(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: EVMFork): CallParams =
  result = CallParams(
    vmState:      vmState,
    forkOverride: some(fork),
    gasPrice:     tx.gasPrice,
    gasLimit:     tx.gasLimit,
    sender:       sender,
    to:           tx.destination,
    isCreate:     tx.contractCreation,
    value:        tx.value,
    input:        tx.payload,

    noIntrinsic:  true, # Don't charge intrinsic gas.
    noRefund:     true, # Don't apply gas refund/burn rule.
  )
  if tx.txType > TxLegacy:
    shallowCopy(result.accessList, tx.accessList)

  if tx.txType >= TxEip4844:
    result.versionedHashes = tx.versionedHashes

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
