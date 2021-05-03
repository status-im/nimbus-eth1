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
  ".."/[db/accounts_cache, p2p/executor], eth/trie/db

type
  RpcCallData* = object
    source*: EthAddress
    to*: EthAddress
    gas*: GasInt
    gasPrice*: GasInt
    value*: UInt256
    data*: seq[byte]
    contractCreation*: bool

proc rpcSetupComputation*(vmState: BaseVMState, call: RpcCallData,
                          fork: Fork, gasLimit: GasInt): Computation =
  vmState.setupTxContext(
    origin = call.source,
    gasPrice = call.gasPrice,
    forkOverride = some(fork)
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
    fork    = toFork(chain.config, header.blockNumber)
    comp    = rpcSetupComputation(vmState, call, fork, call.gas)

  comp.execComputation()
  result = hexDataStr(comp.output)

proc rpcMakeCall*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB): (string, GasInt, bool) =
  # TODO: handle revert
  var
    # we use current header stateRoot, unlike block validation
    # which use previous block stateRoot
    vmState = newBaseVMState(header.stateRoot, header, chain)
    fork    = toFork(chain.config, header.blockNumber)
    comp    = rpcSetupComputation(vmState, call, fork, call.gas)

  let gas = comp.gasMeter.gasRemaining
  comp.execComputation()
  return (comp.output.toHex, gas - comp.gasMeter.gasRemaining, comp.isError)

proc rpcEstimateGas*(call: RpcCallData, header: BlockHeader, chain: BaseChainDB, haveGasLimit: bool): GasInt =
  # TODO: handle revert and error
  var
    # we use current header stateRoot, unlike block validation
    # which use previous block stateRoot
    vmState = newBaseVMState(header.stateRoot, header, chain)
    fork    = toFork(chain.config, header.blockNumber)
    tx      = Transaction(
      accountNonce: vmState.accountdb.getNonce(call.source),
      gasPrice: call.gasPrice,
      gasLimit: if haveGasLimit: call.gas else: header.gasLimit - vmState.cumulativeGasUsed,
      to      : call.to,
      value   : call.value,
      payload : call.data,
      isContractCreation:  call.contractCreation
    )

  var dbTx = chain.db.beginTransaction()
  defer: dbTx.dispose()
  result = processTransaction(tx, call.source, vmState, fork)
  dbTx.dispose()
