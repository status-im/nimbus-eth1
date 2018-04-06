import
  strformat, ttmath,
  ../../../constants, ../../../errors, ../../../vm_state, ../../../transaction, ../../../utils/header

proc validateFrontierTransaction*(vmState: BaseVmState, transaction: BaseTransaction) =
  let gasCost = transaction.gas * transaction.gasPrice
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
