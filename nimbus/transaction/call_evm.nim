# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/common/eth_types, stint, options, stew/byteutils,
  ".."/[vm_types, vm_state, vm_gas_costs, forks],
  ".."/[db/db_chain, db/accounts_cache, transaction], eth/trie/db,
  ".."/[chain_config, rpc/hexstrings],
  ./call_common

type
  RpcCallData* = object
    source*: EthAddress
    to*: EthAddress
    gas*: GasInt
    gasPrice*: GasInt
    value*: UInt256
    data*: seq[byte]
    contractCreation*: bool

proc rpcRunComputation(vmState: BaseVMState, rpc: RpcCallData,
                       gasLimit: GasInt, forkOverride = none(Fork),
                       forEstimateGas: bool = false): CallResult =
  return runComputation(CallParams(
    vmState:      vmState,
    forkOverride: forkOverride,
    gasPrice:     rpc.gasPrice,
    gasLimit:     gasLimit,
    sender:       rpc.source,
    to:           rpc.to,
    isCreate:     rpc.contractCreation,
    value:        rpc.value,
    input:        rpc.data,
    # This matches historical behaviour.  It might be that not all these steps
    # should be disabled for RPC/GraphQL `call`.  But until we investigate what
    # RPC/GraphQL clients are expecting, keep the same behaviour.
    noIntrinsic:  not forEstimateGas,   # Don't charge intrinsic gas.
    noAccessList: not forEstimateGas,   # Don't initialise EIP-2929 access list.
    noGasCharge:  not forEstimateGas,   # Don't charge sender account for gas.
    noRefund:     not forEstimateGas    # Don't apply gas refund/burn rule.
  ))

proc rpcDoCall*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB): HexDataStr =
  # TODO: handle revert and error
  # TODO: handle contract ABI
  # we use current header stateRoot, unlike block validation
  # which use previous block stateRoot
  # TODO: ^ Check it's correct to use current header stateRoot, not parent
  let vmState    = newBaseVMState(header.stateRoot, header, chain)
  let callResult = rpcRunComputation(vmState, call, call.gas)
  return hexDataStr(callResult.output)

proc rpcMakeCall*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB): (string, GasInt, bool) =
  # TODO: handle revert
  let parent     = chain.getBlockHeader(header.parentHash)
  let vmState    = newBaseVMState(parent.stateRoot, header, chain)
  let callResult = rpcRunComputation(vmState, call, call.gas)
  return (callResult.output.toHex, callResult.gasUsed, callResult.isError)

func rpcIntrinsicGas(call: RpcCallData, fork: Fork): GasInt =
  var intrinsicGas = call.data.intrinsicGas(fork)
  if call.contractCreation:
    intrinsicGas = intrinsicGas + gasFees[fork][GasTXCreate]
  return intrinsicGas

func rpcValidateCall(call: RpcCallData, vmState: BaseVMState, gasLimit: GasInt,
                     fork: Fork): bool =
  # This behaviour matches `validateTransaction`, used by `processTransaction`.
  if vmState.cumulativeGasUsed + gasLimit > vmState.blockHeader.gasLimit:
    return false
  let balance = vmState.readOnlyStateDB.getBalance(call.source)
  let gasCost = gasLimit.u256 * call.gasPrice.u256
  if gasCost > balance or call.value > balance - gasCost:
    return false
  let intrinsicGas = rpcIntrinsicGas(call, fork)
  if intrinsicGas > gasLimit:
    return false
  return true

proc rpcEstimateGas*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB, haveGasLimit: bool): GasInt =
  # TODO: handle revert and error
  var
    # we use current header stateRoot, unlike block validation
    # which use previous block stateRoot
    vmState = newBaseVMState(header.stateRoot, header, chain)
    fork    = toFork(chain.config, header.blockNumber)
    gasLimit = if haveGasLimit: call.gas else: header.gasLimit - vmState.cumulativeGasUsed

  # Nimbus `estimateGas` has historically checked against remaining gas in the
  # current block, balance in the sender account (even if the sender is default
  # account 0x00), and other limits, and returned 0 as the gas estimate if any
  # checks failed.  This behaviour came from how it used `processTransaction`
  # which calls `validateTransaction`.  For now, keep this behaviour the same.
  # Compare this code with `validateTransaction`.
  #
  # TODO: This historically differs from `rpcDoCall` and `rpcMakeCall`.  There
  # are other differences in rpc_utils.nim `callData` too.  Are the different
  # behaviours intended, and is 0 the correct return value to mean "not enough
  # gas to start"?  Probably not.
  if not rpcValidateCall(call, vmState, gasLimit, fork):
    return 0

  # Use a db transaction to save and restore the state of the database.
  var dbTx = chain.db.beginTransaction()
  defer: dbTx.dispose()

  let callResult = rpcRunComputation(vmState, call, gasLimit, some(fork), true)
  return callResult.gasUsed

proc txCallEvm*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): GasInt =
  var call = CallParams(
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
    shallowCopy(call.accessList, tx.accessList)
  return runComputation(call).gasUsed

proc testCallEvm*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): CallResult =
  var call = CallParams(
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
    shallowCopy(call.accessList, tx.accessList)
  runComputation(call)
