# Nimbus - Various ways of calling the EVM
#
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  eth/common/[addresses, transactions],
  ../evm/types,
  ../transaction,
  ./call_common

export
  call_common

proc callParams*(tx: Transaction,
                 sender: Address,
                 vmState: BaseVMState,
                 intrinsic: IntrinsicGas): CallParams =
  let
    baseFee = vmState.blockCtx.baseFeePerGas
  CallParams(
    vmState          : vmState,
    effectiveGasPrice: tx.effectiveGasPrice(baseFee),
    sender           : sender,
    isCreate         : tx.contractCreation,
    tx               : tx.addr,
    intrinsic        : intrinsic
  )

proc txCallEvm*(tx: Transaction,
                sender: Address,
                vmState: BaseVMState,
                intrinsic: IntrinsicGas,
                T: type = TxResult): T =
  let call = callParams(tx, sender, vmState, intrinsic)
  runComputation(call, T)
