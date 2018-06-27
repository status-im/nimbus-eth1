# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  eth_common/eth_types,
  ../../../constants, ../../../errors, ../../../vm_state, ../../../transaction, ../../../utils/header

proc validateTangerineTransaction*(vmState: BaseVmState, transaction: BaseTransaction) =
  let gasCost = u256(transaction.gas * transaction.gasPrice)
  var senderBalance: UInt256
  # inDB(vmState.stateDB(readOnly=true):
  #   senderBalance = db.getBalance(transaction.sender)
  senderBalance = gasCost # TODO
  if senderBalance < gasCost:
    raise newException(ValidationError, &"Sender account balance cannot afford txn gas: {transaction.sender}")

  let totalCost = transaction.value + gasCost

  if senderBalance < totalCost:
    raise newException(ValidationError, "Sender account balance cannot afford txn")

  if vmState.blockHeader.gasUsed + transaction.gas > vmState.blockHeader.gasLimit:
    raise newException(ValidationError, "Transaction exceeds gas limit")

  # inDB(vmState.stateDb(readOnly=true):
  #   if db.getNonce(transaction.sender) != transaction.nonce:
  #     raise newException(ValidationError, "Invalid transaction nonce")
