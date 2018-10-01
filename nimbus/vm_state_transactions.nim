# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ranges/typedranges, sequtils, strformat, tables,
  eth_common,
  ./constants, ./errors, ./vm/computation,
  ./transaction, ./vm_types, ./vm_state, ./block_types, ./db/[db_chain, state_db], ./utils/header,
  ./vm/interpreter, ./utils/addresses

func intrinsicGas*(data: openarray[byte]): GasInt =
  result = 21_000
  for i in data:
    if i == 0:
      result += 4
    else:
      result += 68

proc validateTransaction*(vmState: BaseVMState, transaction: Transaction, sender: EthAddress): bool =
  # XXX: https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  # XXX: lots of avoidable u256 construction
  var readOnlyDB = vmState.readOnlyStateDB
  let limitAndValue = transaction.gasLimit.u256 + transaction.value
  let gas_cost = transaction.gasLimit.u256 * transaction.gasPrice.u256

  transaction.gasLimit >= transaction.payload.intrinsicGas and
    transaction.gasPrice <= (1 shl 34) and
    limitAndValue <= readOnlyDB.getBalance(sender) and
    transaction.accountNonce == readOnlyDB.getNonce(sender) and
    readOnlyDB.getBalance(sender) >= gas_cost

proc setupComputation*(header: BlockHeader, vmState: var BaseVMState, transaction: Transaction, sender: EthAddress) : BaseComputation =
  let message = newMessage(
      gas = transaction.gasLimit - transaction.payload.intrinsicGas,
      gasPrice = transaction.gasPrice,
      to = transaction.to,
      sender = sender,
      value = transaction.value,
      data = transaction.payload,
      code = vmState.readOnlyStateDB.getCode(transaction.to).toSeq,
      options = newMessageOptions(origin = sender,
                                  createAddress = transaction.to))

  result = newBaseComputation(vmState, header.blockNumber, message)
  result.precompiles = initTable[string, Opcode]()
  doAssert result.isOriginComputation

proc execComputation*(computation: var BaseComputation): bool =
  try:
    computation.executeOpcodes()
    computation.vmState.mutateStateDB:
      for deletedAccount in computation.getAccountsForDeletion:
        db.deleteAccount deletedAccount

    result = not computation.isError
  except ValueError:
    result = false

proc applyCreateTransaction*(db: var AccountStateDB, t: Transaction, head: BlockHeader, vmState: var BaseVMState, sender: EthAddress, useHomestead: bool = false): UInt256 =
  doAssert t.isContractCreation
  # TODO: clean up params
  echo "Contract creation"

  let gasUsed = t.payload.intrinsicGas.GasInt + (if useHomestead: 32000 else: 0)

  # TODO: setupComputation refactoring
  let contractAddress = generateAddress(sender, t.accountNonce)
  let msg = newMessage(t.gasLimit - gasUsed, t.gasPrice, t.to, sender, t.value, @[], t.payload,
                       options = newMessageOptions(origin = sender,
                                                   createAddress = contractAddress))
  var c = newBaseComputation(vmState, head.blockNumber, msg)

  if execComputation(c):
    db.addBalance(contractAddress, t.value)

    # XXX: copy/pasted from GST fixture
    # TODO: more merging/refactoring/etc
    # also a couple lines can collapse because variable used once
    # once verified in GST fixture
    let
      gasRemaining = c.gasMeter.gasRemaining.u256
      gasRefunded = c.gasMeter.gasRefunded.u256
      gasUsed2 = t.gasLimit.u256 - gasRemaining
      gasRefund = min(gasRefunded, gasUsed2 div 2)
      gasRefundAmount = (gasRefund + gasRemaining) * t.gasPrice.u256
    #echo "gasRemaining is ", gasRemaining, " and gasRefunded = ", gasRefunded, " and gasUsed2 = ", gasUsed2, " and gasRefund = ", gasRefund, " and gasRefundAmount = ", gasRefundAmount

    var codeCost = 200 * c.output.len

    # This apparently is not supposed to actually consume the gas, just be able to,
    # for purposes of accounting. Py-EVM apparently does consume the gas, but it is
    # not matching observed blockchain balances if consumeGas is called.
    if gasRemaining >= codeCost.u256:
      db.setCode(contractAddress, c.output.toRange)
    else:
      # XXX: Homestead behaves differently; reverts state on gas failure
      # https://github.com/ethereum/py-evm/blob/master/eth/vm/forks/homestead/computation.py
      codeCost = 0
      db.setCode(contractAddress, ByteRange())
    db.addBalance(sender, (t.gasLimit.u256 - gasUsed2 - codeCost.u256)*t.gasPrice.u256)
    return (gasUsed2 + codeCost.u256) * t.gasPrice.u256

  else:
    # FIXME: don't do this revert, but rather only subBalance correctly
    # the if transactionfailed at end is what is supposed to pick it up
    # especially when it's cross-function, it's ugly/fragile
    db.addBalance(sender, t.value)
    echo "isError: ", c.isError
    return t.gasLimit.u256 * t.gasPrice.u256

method executeTransaction(vmState: var BaseVMState, transaction: Transaction): (BaseComputation, BlockHeader) {.base.}=
  # Execute the transaction in the vm
  # TODO: introduced here: https://github.com/ethereum/py-evm/commit/21c57f2d56ab91bb62723c3f9ebe291d0b132dde
  # Refactored/Removed here: https://github.com/ethereum/py-evm/commit/cc991bf
  # Deleted here: https://github.com/ethereum/py-evm/commit/746defb6f8e83cee2c352a0ab8690e1281c4227c
  raise newException(ValueError, "Must be implemented by subclasses")


method addTransaction*(vmState: var BaseVMState, transaction: Transaction, computation: BaseComputation, b: Block): (Block, Table[string, string]) =
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
    vmState: var BaseVMState,
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
