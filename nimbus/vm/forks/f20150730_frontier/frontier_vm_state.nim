# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../../../logging, ../../../constants, ../../../errors, ../../../vm_state,
  ../../../utils/header, ../../../db/db_chain

type
  FrontierVMState* = ref object of BaseVMState
    # receipts*:
    # computationClass*: Any
    # accessLogs*: AccessLogs

proc newFrontierVMState*: FrontierVMState =
  new(result)
  result.prevHeaders = @[]
  result.name = "FrontierVM"
  result.accessLogs = newAccessLogs()
  # result.blockHeader = # TODO: ...

# import
#   py2nim_helpers, __future__, rlp, evm, evm.constants, evm.exceptions, evm.rlp.logs,
#   evm.rlp.receipts, evm.vm.message, evm.vm_state, evm.utils.address,
#   evm.utils.hexadecimal, evm.utils.keccak, evm.validation, computation, constants,
#   validation

# type
#   FrontierVMState* = object of Function
#     prevHeaders*: seq[BlockHeader]
#     receipts*: void
#     computationClass*: Any
#     _chaindb*: BaseChainDB
#     accessLogs*: AccessLogs
#     blockHeader*: BlockHeader

# proc _executeFrontierTransaction*(vmState: FrontierVMState;
#                                  transaction: FrontierTransaction): FrontierComputation =
#   transaction.validate()
#   validateFrontierTransaction(vmState, transaction)
#   var gasFee = transaction.gas * transaction.gasPrice
#   with vmState.stateDb(),
#     stateDb.deltaBalance(transaction.sender, -1 * gasFee)
#     stateDb.incrementNonce(transaction.sender)
#     var messageGas = transaction.gas - transaction.intrinsicGas
#     if transaction.to == constants.CREATECONTRACTADDRESS:
#       var
#         contractAddress = generateContractAddress(transaction.sender,
#             stateDb.getNonce(transaction.sender) - 1)
#         data = cstring""
#         code = transaction.data
#     else:
#       contractAddress = None
#       data = transaction.data
#       code = stateDb.getCode(transaction.to)
#   vmState.logger.info("TRANSACTION: sender: %s | to: %s | value: %s | gas: %s | gas-price: %s | s: %s | r: %s | v: %s | data-hash: %s",
#                       encodeHex(transaction.sender), encodeHex(transaction.to),
#                       transaction.value, transaction.gas, transaction.gasPrice,
#                       transaction.s, transaction.r, transaction.v,
#                       encodeHex(keccak(transaction.data)))
#   var message = Message()
#   if message.isCreate:
#     with vmState.stateDb(),
#       var isCollision = stateDb.accountHasCodeOrNonce(contractAddress)
#     if isCollision:
#       var computation = vmState.getComputation(message)
#       computation._error = ContractCreationCollision("Address collision while creating contract: {0}".format(
#           encodeHex(contractAddress)))
#       vmState.logger.debug("Address collision while creating contract: %s",
#                            encodeHex(contractAddress))
#     else:
#       computation = vmState.getComputation(message).applyCreateMessage()
#   else:
#     computation = vmState.getComputation(message).applyMessage()
#   var numDeletions = len(computation.getAccountsForDeletion())
#   if numDeletions:
#     computation.gasMeter.refundGas(REFUNDSELFDESTRUCT * numDeletions)
#   var
#     gasRemaining = computation.getGasRemaining()
#     gasRefunded = computation.getGasRefund()
#     gasUsed = transaction.gas - gasRemaining
#     gasRefund = min(gasRefunded, gasUsed div 2)
#     gasRefundAmount = gasRefund + gasRemaining * transaction.gasPrice
#   if gasRefundAmount:
#     vmState.logger.debug("TRANSACTION REFUND: %s -> %s", gasRefundAmount,
#                          encodeHex(message.sender))
#     with vmState.stateDb(),
#       stateDb.deltaBalance(message.sender, gasRefundAmount)
#   var transactionFee = transaction.gas - gasRemaining - gasRefund *
#       transaction.gasPrice
#   vmState.logger.debug("TRANSACTION FEE: %s -> %s", transactionFee,
#                        encodeHex(vmState.coinbase))
#   with vmState.stateDb(),
#     stateDb.deltaBalance(vmState.coinbase, transactionFee)
#   with vmState.stateDb(),
#     for account, beneficiary in computation.getAccountsForDeletion():
#       vmState.logger.debug("DELETING ACCOUNT: %s", encodeHex(account))
#       stateDb.setBalance(account, 0)
#       stateDb.deleteAccount(account)
#   return computation

# proc _makeFrontierReceipt*(vmState: FrontierVMState;
#                           transaction: FrontierTransaction;
#                           computation: FrontierComputation): Receipt =
#   var
#     logs =                     ## py2nim can't generate code for
#          ## Log(address, topics, data)
#     gasRemaining = computation.getGasRemaining()
#     gasRefund = computation.getGasRefund()
#     txGasUsed = transaction.gas - gasRemaining -
#         min(gasRefund, transaction.gas - gasRemaining div 2)
#     gasUsed = vmState.blockHeader.gasUsed + txGasUsed
#     receipt = Receipt()
#   return receipt

# method executeTransaction*(self: FrontierVMState; transaction: FrontierTransaction): (
#     , ) =
#   var computation = _executeFrontierTransaction(self, transaction)
#   return (computation, self.blockHeader)

# method makeReceipt*(self: FrontierVMState; transaction: FrontierTransaction;
#                    computation: FrontierComputation): Receipt =
#   var receipt = _makeFrontierReceipt(self, transaction, computation)
#   return receipt

# method validateBlock*(self: FrontierVMState; block: FrontierBlock): void =
#   if notblock.isGenesis:
#     var parentHeader = self.parentHeader
#     self._validateGasLimit(block)
#     validateLengthLte(block.header.extraData, 32)
#     if block.header.timestamp < parentHeader.timestamp:
#       raise newException(ValidationError, "`timestamp` is before the parent block\'s timestamp.\\n- block  : {0}\\n- parent : {1}. ".format(
#           block.header.timestamp, parentHeader.timestamp))
#     elif block.header.timestamp == parentHeader.timestamp:
#       raise ValidationError("`timestamp` is equal to the parent block\'s timestamp\\n- block : {0}\\n- parent: {1}. ".format(
#           block.header.timestamp, parentHeader.timestamp))
#   if len(block.uncles) > MAXUNCLES:
#     raise newException(ValidationError, "Blocks may have a maximum of {0} uncles.  Found {1}.".format(
#         MAXUNCLES, len(block.uncles)))
#   for uncle in block.uncles:
#     self.validateUncle(block, uncle)
#   if notself.isKeyExists(block.header.stateRoot):
#     raise newException(ValidationError, "`state_root` was not found in the db.\\n- state_root: {0}".format(
#         block.header.stateRoot))
#   var localUncleHash = keccak(rlp.encode(block.uncles))
#   if localUncleHash != block.header.unclesHash:
#     raise newException(ValidationError, "`uncles_hash` and block `uncles` do not match.\\n - num_uncles       : {0}\\n - block uncle_hash : {1}\\n - header uncle_hash: {2}".format(
#         len(block.uncles), localUncleHash, block.header.uncleHash))

# method _validateGasLimit*(self: FrontierVMState; block: FrontierBlock): void =
#   var gasLimit = block.header.gasLimit
#   if gasLimit < GASLIMITMINIMUM:
#     raise newException(ValidationError, "Gas limit {0} is below minimum {1}".format(
#         gasLimit, GASLIMITMINIMUM))
#   if gasLimit > GASLIMITMAXIMUM:
#     raise newException(ValidationError, "Gas limit {0} is above maximum {1}".format(
#         gasLimit, GASLIMITMAXIMUM))
#   var
#     parentGasLimit = self.parentHeader.gasLimit
#     diff = gasLimit - parentGasLimit
#   if diff > parentGasLimit // GASLIMITADJUSTMENTFACTOR:
#     raise newException(ValidationError, "Gas limit {0} difference to parent {1} is too big {2}".format(
#         gasLimit, parentGasLimit, diff))

# proc makeFrontierVMState*(): FrontierVMState =
#   result.computationClass = FrontierComputation

