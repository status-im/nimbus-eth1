# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/common/eth_types, stint, options, stew/byteutils,
  ".."/[vm_types, vm_types2, vm_state, utils],
  ".."/[db/db_chain, config, rpc/hexstrings, utils],
  ".."/[db/accounts_cache, utils, transaction, vm_gas_costs], eth/trie/db,
  ".."/vm_internals,
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
    to:           tx.to,
    isCreate:     tx.isContractCreation,
    value:        tx.value,
    input:        tx.payload
  )
  if tx.txType == AccessListTxType:
    shallowCopy(call.accessList, tx.accessListTx.accessList)
  return runComputation(call).gasUsed

type
  AsmResult* = object
    isSuccess*:       bool
    gasUsed*:         GasInt
    output*:          seq[byte]
    stack*:           Stack
    memory*:          Memory
    vmState*:         BaseVMState
    contractAddress*: EthAddress

proc asmCallEvm*(blockNumber: Uint256, chainDB: BaseChainDB, code, data: seq[byte], fork: Fork): AsmResult =
  let
    parentNumber = blockNumber - 1
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = chainDB.getBlockBody(headerHash)
    vmState = newBaseVMState(parent.stateRoot, header, chainDB)
    tx = body.transactions[0]
    sender = transaction.getSender(tx)
    gasLimit = 500000000
    gasUsed = 0 #tx.payload.intrinsicGas.GasInt + gasFees[fork][GasTXCreate]

  # This is an odd sort of test, where some fields are taken from
  # `body.transactions[0]` but other fields (like `gasLimit`) are not.  Also it
  # creates the new contract using `code` like `CREATE`, but then executes the
  # contract like it's `CALL`.

  doAssert tx.isContractCreation
  let contractAddress = generateAddress(sender, vmState.readOnlyStateDB.getNonce(sender))
  vmState.mutateStateDB:
    db.setCode(contractAddress, code)

  let callResult = runComputation(CallParams(
    vmState:      vmState,
    forkOverride: some(fork),
    gasPrice:     tx.gasPrice,
    gasLimit:     gasLimit - gasUsed,
    sender:       sender,
    to:           contractAddress,
    isCreate:     false,
    value:        tx.value,
    input:        data,
    noIntrinsic:  true,               # Don't charge intrinsic gas.
    noAccessList: true,               # Don't initialise EIP-2929 access list.
    noGasCharge:  true,               # Don't charge sender account for gas.
    noRefund:     true                # Don't apply gas refund/burn rule.
  ))

  # Some of these are extra returned state, for testing, that a normal EVMC API
  # computation doesn't return.  We'll have to obtain them outside EVMC.
  result.isSuccess       = not callResult.isError
  result.gasUsed         = callResult.gasUsed
  result.output          = callResult.output
  result.stack           = callResult.stack
  result.memory          = callResult.memory
  result.vmState         = vmState
  result.contractAddress = contractAddress

type
  FixtureResult* = object
    isError*:         bool
    error*:           Error
    gasUsed*:         GasInt
    output*:          seq[byte]
    vmState*:         BaseVMState
    logEntries*:      seq[Log]

proc fixtureCallEvm*(vmState: BaseVMState, call: RpcCallData,
                     origin: EthAddress, forkOverride = none(Fork)): FixtureResult =
  let callResult = runComputation(CallParams(
    vmState:      vmState,
    forkOverride: forkOverride,
    origin:       some(origin),       # Differs from `rpcSetupComputation`.
    gasPrice:     call.gasPrice,
    gasLimit:     call.gas,           # Differs from `rpcSetupComputation`.
    sender:       call.source,
    to:           call.to,
    isCreate:     call.contractCreation,
    value:        call.value,
    input:        call.data,
    noIntrinsic:  true,               # Don't charge intrinsic gas.
    noAccessList: true,               # Don't initialise EIP-2929 access list.
    noGasCharge:  true,               # Don't charge sender account for gas.
    noRefund:     true,               # Don't apply gas refund/burn rule.
    noTransfer:   true,               # Don't update balances, nonces, code.
  ))

  # Some of these are extra returned state, for testing, that a normal EVMC API
  # computation doesn't return.  We'll have to obtain them outside EVMC.
  result.isError         = callResult.isError
  result.error           = callResult.error
  result.gasUsed         = callResult.gasUsed
  result.output          = callResult.output
  result.vmState         = vmState
  shallowCopy(result.logEntries, callResult.logEntries)
