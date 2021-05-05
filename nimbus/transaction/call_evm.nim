# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/common/eth_types, stint, options, stew/byteutils,
  ".."/[vm_types, vm_types2, vm_state, vm_computation, utils],
  ".."/[db/db_chain, config, vm_state_transactions, rpc/hexstrings],
  ".."/[db/accounts_cache, transaction, vm_precompiles, vm_gas_costs], eth/trie/db,
  ".."/vm_internals

type
  RpcCallData* = object
    source*: EthAddress
    to*: EthAddress
    gas*: GasInt
    gasPrice*: GasInt
    value*: UInt256
    data*: seq[byte]
    contractCreation*: bool

proc rpcSetupComputation(vmState: BaseVMState, call: RpcCallData,
                         gasLimit: GasInt, forkOverride = none(Fork)): Computation =
  vmState.setupTxContext(
    origin = call.source,
    gasPrice = call.gasPrice,
    forkOverride = forkOverride,
  )

  var msg = Message(
    kind: if call.contractCreation: evmcCreate else: evmcCall,
    depth: 0,
    gas: gasLimit,
    sender: call.source,
    contractAddress:
      if not call.contractCreation:
        call.to
      else:
        generateAddress(call.source, vmState.readOnlyStateDB.getNonce(call.source)),
    codeAddress: call.to,
    value: call.value,
    data: call.data
  )

  return newComputation(vmState, msg)

proc rpcDoCall*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB): HexDataStr =
  # TODO: handle revert and error
  # TODO: handle contract ABI
  var
    # we use current header stateRoot, unlike block validation
    # which use previous block stateRoot
    vmState = newBaseVMState(header.stateRoot, header, chain)
    comp    = rpcSetupComputation(vmState, call, call.gas)

  comp.execComputation()
  result = hexDataStr(comp.output)

proc rpcMakeCall*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB): (string, GasInt, bool) =
  # TODO: handle revert
  var
    # we use current header stateRoot, unlike block validation
    # which use previous block stateRoot
    vmState = newBaseVMState(header.stateRoot, header, chain)
    comp    = rpcSetupComputation(vmState, call, call.gas)

  let gas = comp.gasMeter.gasRemaining
  comp.execComputation()
  return (comp.output.toHex, gas - comp.gasMeter.gasRemaining, comp.isError)

func rpcIntrinsicGas(call: RpcCallData, fork: Fork): GasInt =
  var intrinsicGas = call.data.intrinsicGas(fork)
  if call.contractCreation:
    intrinsicGas = intrinsicGas + gasFees[fork][GasTXCreate]
  return intrinsicGas

func rpcValidateCall(call: RpcCallData, vmState: BaseVMState, gasLimit: GasInt,
                     fork: Fork, intrinsicGas: var GasInt, gasCost: var UInt256): bool =
  # This behaviour matches `validateTransaction`, used by `processTransaction`.
  if vmState.cumulativeGasUsed + gasLimit > vmState.blockHeader.gasLimit:
    return false
  let balance = vmState.readOnlyStateDB.getBalance(call.source)
  gasCost = gasLimit.u256 * call.gasPrice.u256
  if gasCost > balance or call.value > balance - gasCost:
    return false
  intrinsicGas = rpcIntrinsicGas(call, fork)
  if intrinsicGas > gasLimit:
    return false
  return true

proc rpcInitialAccessListEIP2929(call: RpcCallData, vmState: BaseVMState, fork: Fork) =
  # EIP2929 initial access list.
  if fork >= FkBerlin:
    vmState.mutateStateDB:
      db.accessList(call.source)
      # For contract creations the EVM will add the contract address to the
      # access list itself, after calculating the new contract address.
      if not call.contractCreation:
        db.accessList(call.to)
      for c in activePrecompiles():
        db.accessList(c)

proc rpcEstimateGas*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB, haveGasLimit: bool): GasInt =
  # TODO: handle revert and error
  var
    # we use current header stateRoot, unlike block validation
    # which use previous block stateRoot
    vmState = newBaseVMState(header.stateRoot, header, chain)
    fork    = toFork(chain.config, header.blockNumber)
    gasLimit = if haveGasLimit: call.gas else: header.gasLimit - vmState.cumulativeGasUsed
    intrinsicGas: GasInt
    gasCost: UInt256

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
  if not rpcValidateCall(call, vmState, gasLimit, fork, intrinsicGas, gasCost):
    return 0

  var dbTx = chain.db.beginTransaction()
  defer: dbTx.dispose()

  # TODO: EIP2929 setup also historically differs from `rpcDoCall` and `rpcMakeCall`.
  rpcInitialAccessListEIP2929(call, vmState, fork)

  # TODO: Deduction of `intrinsicGas` also differs from `rpcDoCall` and `rpcMakeCall`.
  var c = rpcSetupComputation(vmState, call, gasLimit - intrinsicGas, some(fork))
  vmState.mutateStateDB:
    db.subBalance(call.source, gasCost)

  execComputation(c)

  if c.shouldBurnGas:
    return gasLimit
  let maxRefund = (gasLimit - c.gasMeter.gasRemaining) div 2
  let refund = min(c.getGasRefund(), maxRefund)
  return gasLimit - c.gasMeter.gasRemaining - refund

proc txSetupComputation(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): Computation =
  var gas = tx.gasLimit - tx.intrinsicGas(fork)
  assert gas >= 0

  vmState.setupTxContext(
    origin = sender,
    gasPrice = tx.gasPrice,
    forkOverride = some(fork)
  )

  let msg = Message(
    kind: if tx.isContractCreation: evmcCreate else: evmcCall,
    depth: 0,
    gas: gas,
    sender: sender,
    contractAddress: tx.getRecipient(sender),
    codeAddress: tx.to,
    value: tx.value,
    data: tx.payload
    )

  result = newComputation(vmState, msg)
  doAssert result.isOriginComputation

proc txRefundgas(tx: Transaction, sender: EthAddress, c: Computation) =
  let maxRefund = (tx.gasLimit - c.gasMeter.gasRemaining) div 2
  let refund = min(c.getGasRefund(), maxRefund)
  c.gasMeter.returnGas(refund)
  c.vmState.mutateStateDB:
    db.addBalance(sender, c.gasMeter.gasRemaining.u256 * tx.gasPrice.u256)

proc txInitialAccessListEIP2929(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork) =
  # EIP2929 initial access list.
  if fork >= FkBerlin:
    vmState.mutateStateDB:
      db.accessList(sender)
      # For contract creations the EVM will add the contract address to the
      # access list itself, after calculating the new contract address.
      if not tx.isContractCreation:
        db.accessList(tx.getRecipient(sender))
      for c in activePrecompiles():
        db.accessList(c)

proc txCallEvm*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): GasInt =
  txInitialAccessListEIP2929(tx, sender, vmState, fork)

  var c = txSetupComputation(tx, sender, vmState, fork)
  vmState.mutateStateDB:
    db.subBalance(sender, tx.gasLimit.u256 * tx.gasPrice.u256)

  execComputation(c)

  if c.shouldBurnGas:
    return tx.gasLimit
  txRefundGas(tx, sender, c)
  return tx.gasLimit - c.gasMeter.gasRemaining

proc asmSetupComputation(tx: Transaction, sender: EthAddress, vmState: BaseVMState,
                         data: seq[byte], forkOverride = none(Fork)): Computation =
  doAssert tx.isContractCreation

  let gasUsed = 0 #tx.payload.intrinsicGas.GasInt + gasFees[fork][GasTXCreate]

  vmState.setupTxContext(
    origin = sender,
    gasPrice = tx.gasPrice,
    forkOverride = forkOverride,
  )

  let contractAddress = generateAddress(sender, tx.accountNonce)
  let msg = Message(
      kind: evmcCall,
      depth: 0,
      gas: tx.gasLimit - gasUsed,
      sender: sender,
      contractAddress: contractAddress,
      codeAddress: contractAddress,
      value: tx.value,
      data: data
      )

  vmState.mutateStateDb:
    db.setCode(contractAddress, tx.payload)

  return newComputation(vmState, msg)

proc asmSetupComputation(blockNumber: Uint256, chainDB: BaseChainDB, code,
                         data: seq[byte], forkOverride = none(Fork)): Computation =
  let
    parentNumber = blockNumber - 1
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    body = chainDB.getBlockBody(headerHash)
    vmState = newBaseVMState(parent.stateRoot, header, chainDB)

  var
    tx = body.transactions[0]
    sender = transaction.getSender(tx)

  tx.payload = code
  tx.gasLimit = 500000000
  return asmSetupComputation(tx, sender, vmState, data, forkOverride)

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
  var c = asmSetupComputation(blockNumber, chainDB, code, data, some(fork))
  let gas = c.gasMeter.gasRemaining
  c.execComputation()

  # Some of these are extra returned state, for testing, that a normal EVMC API
  # computation doesn't return.  We'll have to obtain them outside EVMC.
  result.isSuccess       = c.isSuccess
  result.gasUsed         = gas - c.gasMeter.gasRemaining
  result.output          = c.output
  result.stack           = c.stack
  result.memory          = c.memory
  result.vmState         = c.vmState
  result.contractAddress = c.msg.contractAddress

proc fixtureSetupComputation(vmState: BaseVMState, call: RpcCallData,
                             origin: EthAddress, forkOverride = none(Fork)): Computation =
  vmState.setupTxContext(
    origin = origin,          # Differs from `rpcSetupComputation`
    gasPrice = call.gasPrice,
    forkOverride = forkOverride,
  )

  var msg = Message(
    kind: if call.contractCreation: evmcCreate else: evmcCall,
    depth: 0,
    gas: call.gas,            # Differs from `rpcSetupComputation`
    sender: call.source,
    contractAddress: call.to, # Differs from `rpcSetupComputation`
    codeAddress: call.to,
    value: call.value,
    data: call.data
  )

  return newComputation(vmState, msg)

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
  var c = fixtureSetupComputation(vmState, call, origin, forkOverride)
  let gas = c.gasMeter.gasRemaining

  # Next line differs from all the other EVM calls.  With `execComputation`,
  # most "vm json tests" fail with either `balanceDiff` or `nonceDiff` errors.
  c.executeOpcodes()

  # Some of these are extra returned state, for testing, that a normal EVMC API
  # computation doesn't return.  We'll have to obtain them outside EVMC.
  result.isError         = c.isError
  result.error           = c.error
  result.gasUsed         = gas - c.gasMeter.gasRemaining
  result.output          = c.output
  result.vmState         = c.vmState
  shallowCopy(result.logEntries, c.logEntries)
