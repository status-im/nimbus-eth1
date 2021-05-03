# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth/common/eth_types, stint, options,
  ".."/[vm_types, vm_types2, vm_state, vm_computation],
  ".."/[db/db_chain, config, vm_state_transactions, rpc/hexstrings]

type
  RpcCallData* = object
    source*: EthAddress
    to*: EthAddress
    gas*: GasInt
    gasPrice*: GasInt
    value*: UInt256
    data*: seq[byte]
    contractCreation*: bool

proc rpcSetupComputation*(vmState: BaseVMState, call: RpcCallData, fork: Fork): Computation =
  vmState.setupTxContext(
    origin = call.source,
    gasPrice = call.gasPrice,
    forkOverride = some(fork)
  )

  let msg = Message(
    kind: evmcCall,
    depth: 0,
    gas: call.gas,
    sender: call.source,
    contractAddress: call.to,
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
    comp    = rpcSetupComputation(vmState, call, fork)

  comp.execComputation()
  result = hexDataStr(comp.output)
