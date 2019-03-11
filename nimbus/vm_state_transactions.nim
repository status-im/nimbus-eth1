# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ranges/typedranges, sequtils, strformat, tables, options,
  eth/common, chronicles, ./db/[db_chain, state_db],
  constants, errors, transaction, vm_types, vm_state, utils,
  ./vm/[computation, interpreter], ./vm/interpreter/gas_costs

proc validateTransaction*(vmState: BaseVMState, transaction: Transaction, sender: EthAddress): bool =
  # XXX: https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  # XXX: lots of avoidable u256 construction
  var readOnlyDB = vmState.readOnlyStateDB
  let limitAndValue = transaction.gasLimit.u256 + transaction.value
  let gasCost = transaction.gasLimit.u256 * transaction.gasPrice.u256

  transaction.gasLimit >= transaction.intrinsicGas and
    transaction.gasPrice <= (1 shl 34) and
    limitAndValue <= readOnlyDB.getBalance(sender) and
    transaction.accountNonce == readOnlyDB.getNonce(sender) and
    readOnlyDB.getBalance(sender) >= gasCost

proc setupComputation*(vmState: BaseVMState, tx: Transaction, sender: EthAddress, forkOverride=none(Fork)) : BaseComputation =
  let fork =
    if forkOverride.isSome:
      forkOverride.get
    else:
      vmState.blockNumber.toFork

  var recipient: EthAddress
  var gas = tx.gasLimit - tx.intrinsicGas

  # TODO: refactor message to use byterange
  # instead of seq[byte]
  var data, code: seq[byte]

  if tx.isContractCreation:
    recipient = generateAddress(sender, tx.accountNonce)
    gas = gas - gasFees[fork][GasTXCreate]
    data = @[]
    code = tx.payload
  else:
    recipient = tx.to
    data = tx.payload
    code = vmState.readOnlyStateDB.getCode(tx.to).toSeq

  let msg = newMessage(
    gas = gas,
    gasPrice = tx.gasPrice,
    to = tx.to,
    sender = sender,
    value = tx.value,
    data = data,
    code = code,
    options = newMessageOptions(origin = sender,
                                createAddress = recipient))

  result = newBaseComputation(vmState, vmState.blockNumber, msg, forkOverride)
  doAssert result.isOriginComputation

proc execComputation*(computation: var BaseComputation): bool =
  var snapshot = computation.snapshot()
  defer: snapshot.dispose()

  computation.vmState.mutateStateDB:
    db.subBalance(computation.msg.origin, computation.msg.value)
    db.addBalance(computation.msg.storageAddress, computation.msg.value)

  try:
    computation.executeOpcodes()
    computation.vmState.mutateStateDB:
      for deletedAccount in computation.getAccountsForDeletion:
        db.deleteAccount deletedAccount
    result = not computation.isError
  except ValueError:
    result = false
    debug "execComputation() error", msg = getCurrentExceptionMsg()

  if result:
    snapshot.commit()
    computation.vmState.addLogs(computation.logEntries)
  else:
    snapshot.revert()
    if computation.tracingEnabled: computation.traceError()

proc refundGas*(computation: BaseComputation, tx: Transaction, sender: EthAddress): GasInt =
  let
    gasRemaining = computation.gasMeter.gasRemaining
    gasRefunded = computation.getGasRefund()
    gasUsed = tx.gasLimit - gasRemaining
    gasRefund = min(gasRefunded, gasUsed div 2)

  computation.vmState.mutateStateDB:
    db.addBalance(sender, (gasRemaining + gasRefund).u256 * tx.gasPrice.u256)

  result = gasUsed - gasRefund

proc writeContract*(computation: var BaseComputation) =
  let codeCost = computation.gasCosts[Create].m_handler(0, 0, computation.output.len)
  let contractAddress = computation.msg.storageAddress
  if not computation.isSuicided(contractAddress):
    # make changes only if it not selfdestructed
    if computation.gasMeter.gasRemaining >= codeCost:
      computation.gasMeter.consumeGas(codeCost, reason = "Write contract code for CREATE")
      computation.vmState.mutateStateDB:
        db.setCode(contractAddress, computation.output.toRange)
    else:
      # XXX: Homestead behaves differently; reverts state on gas failure
      # https://github.com/ethereum/py-evm/blob/master/eth/vm/forks/homestead/computation.py
      computation.vmState.mutateStateDB:
        db.setCode(contractAddress, ByteRange())

#[
method executeTransaction(vmState: BaseVMState, transaction: Transaction): (BaseComputation, BlockHeader) {.base.}=
  # Execute the transaction in the vm
  # TODO: introduced here: https://github.com/ethereum/py-evm/commit/21c57f2d56ab91bb62723c3f9ebe291d0b132dde
  # Refactored/Removed here: https://github.com/ethereum/py-evm/commit/cc991bf
  # Deleted here: https://github.com/ethereum/py-evm/commit/746defb6f8e83cee2c352a0ab8690e1281c4227c
  raise newException(ValueError, "Must be implemented by subclasses")


method addTransaction*(vmState: BaseVMState, transaction: Transaction, computation: BaseComputation, b: Block): (Block, Table[string, string]) =
  # Add a transaction to the given block and
  # return `trieData` to store the transaction data in chaindb in VM layer
  # Update the bloomFilter, transaction trie and receipt trie roots, bloom_filter,
  # bloom, and usedGas of the block
  # transaction: the executed transaction
  # computation: the Computation object with executed result
  # block: the Block which the transaction is added in
  # var receipt = vmState.makeReceipt(transaction, computation)
  # vmState.add_receipt(receipt)

  # block.transactions.append(transaction)

  #       # Get trie roots and changed key-values.
  #       tx_root_hash, tx_kv_nodes = make_trie_root_and_nodes(block.transactions)
  #       receipt_root_hash, receipt_kv_nodes = make_trie_root_and_nodes(self.receipts)

  #       trie_data = merge(tx_kv_nodes, receipt_kv_nodes)

  #       block.bloom_filter |= receipt.bloom

  #       block.header.transaction_root = tx_root_hash
  #       block.header.receipt_root = receipt_root_hash
  #       block.header.bloom = int(block.bloom_filter)
  #       block.header.gas_used = receipt.gas_used

  #       return block, trie_data
  result = (b, initTable[string, string]())

method applyTransaction*(
    vmState: BaseVMState,
    transaction: Transaction,
    b: Block,
    isStateless: bool): (BaseComputation, Block, Table[string, string]) =
  # Apply transaction to the given block
  # transaction: the transaction need to be applied
  # b: the block which the transaction applies on
  # isStateless: if isStateless, call vmState.addTransaction to set block

  if isStateless:
    var ourBlock = b # deepcopy
    vmState.blockHeader = b.header
    var (computation, blockHeader) = vmState.executeTransaction(transaction)

    ourBlock.header = blockHeader
    var trieData: Table[string, string]
    (ourBlock, trieData) = vmState.addTransaction(transaction, computation, ourBlock)

    result = (computation, ourBlock, trieData)
  else:
    var (computation, blockHeader) = vmState.executeTransaction(transaction)
    return (computation, nil, initTable[string, string]())
]#