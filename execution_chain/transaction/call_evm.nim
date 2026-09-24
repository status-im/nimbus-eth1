# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/eth_types_rlp,
  ../evm/[types, state],
  ../transaction,
  ./call_common,
  web3/eth_api_types,
  ../common/common

export
  call_common

proc callParams*(tx: Transaction,
                 sender: Address,
                 vmState: BaseVMState,
                 intrinsic: IntrinsicGas): CallParams =
  # Is there a nice idiom for this kind of thing? Should I
  # just be writing this as a bunch of assignment statements?
  let
    baseFee = vmState.blockCtx.baseFeePerGas
  CallParams(
    vmState:   vmState,
    gasPrice:  tx.effectiveGasPrice(baseFee),
    sender:    sender,
    isCreate:  tx.contractCreation,
    tx:        tx.addr,
    intrinsic: intrinsic
  )

proc txCallEvm*(tx: Transaction,
                sender: Address,
                vmState: BaseVMState,
                intrinsic: IntrinsicGas,
                discardResult: static bool = false): auto =
  let
    call = callParams(tx, sender, vmState, intrinsic)
  when discardResult:
    discard runComputation(call, VoidResult)
  else:
    runComputation(call, LogResult)

proc testCallEvm*(tx: Transaction,
                  sender: Address,
                  vmState: BaseVMState): DebugCallResult =
  let
    call = callParams(tx, sender, vmState, IntrinsicGas())
  runComputation(call, DebugCallResult)
