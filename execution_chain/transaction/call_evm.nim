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
  stew/assign2,
  ../evm/[types, state],
  ../transaction,
  ./call_common,
  web3/eth_api_types,
  ../common/common

export
  call_common

proc callParamsForTx(tx: Transaction, sender: Address, vmState: BaseVMState, baseFee: GasInt): CallParams =
  # Is there a nice idiom for this kind of thing? Should I
  # just be writing this as a bunch of assignment statements?
  result = CallParams(
    vmState:      vmState,
    gasPrice:     tx.effectiveGasPrice(baseFee),
    gasLimit:     tx.gasLimit,
    sender:       sender,
    to:           tx.destination,
    isCreate:     tx.contractCreation,
    value:        tx.value,
    input:        tx.payload
  )
  if tx.txType > TxLegacy:
    assign(result.accessList, tx.accessList)

  if tx.txType == TxEip4844:
    assign(result.versionedHashes, tx.versionedHashes)

  if tx.txType == TxEip7702:
    assign(result.authorizationList, tx.authorizationList)

proc callParamsForTest(tx: Transaction, sender: Address, vmState: BaseVMState): CallParams =
  result = CallParams(
    vmState:      vmState,
    gasPrice:     tx.gasPrice,
    gasLimit:     tx.gasLimit,
    sender:       sender,
    to:           tx.destination,
    isCreate:     tx.contractCreation,
    value:        tx.value,
    input:        tx.payload,
  )
  if tx.txType > TxLegacy:
    assign(result.accessList, tx.accessList)

  if tx.txType == TxEip4844:
    assign(result.versionedHashes, tx.versionedHashes)

  if tx.txType == TxEip7702:
    assign(result.authorizationList, tx.authorizationList)

proc txCallEvm*(tx: Transaction,
                sender: Address,
                vmState: BaseVMState, baseFee: GasInt): LogResult =
  let
    call = callParamsForTx(tx, sender, vmState, baseFee)
  runComputation(call, LogResult)

proc testCallEvm*(tx: Transaction,
                  sender: Address,
                  vmState: BaseVMState): DebugCallResult =
  let call = callParamsForTest(tx, sender, vmState)
  runComputation(call, DebugCallResult)
