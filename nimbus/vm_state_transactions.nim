# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/ranges/typedranges, options, sets,
  eth/common, chronicles, ./db/state_db,
  transaction, vm_types, vm_state,
  ./vm/[computation, interpreter]

proc validateTransaction*(vmState: BaseVMState, tx: Transaction, sender: EthAddress, fork: Fork): bool =
  # XXX: https://github.com/status-im/nimbus/issues/35#issuecomment-391726518
  # XXX: lots of avoidable u256 construction
  let
    account = vmState.readOnlyStateDB.getAccount(sender)
    gasLimit = tx.gasLimit.u256
    limitAndValue = gasLimit + tx.value
    gasCost = gasLimit * tx.gasPrice.u256

  tx.gasLimit >= tx.intrinsicGas(fork) and
    #transaction.gasPrice <= (1 shl 34) and
    limitAndValue <= account.balance and
    tx.accountNonce == account.nonce and
    account.balance >= gasCost

proc setupComputation*(vmState: BaseVMState, tx: Transaction, sender, recipient: EthAddress, fork: Fork) : Computation =
  var gas = tx.gasLimit - tx.intrinsicGas(fork)

  # TODO: refactor message to use byterange
  # instead of seq[byte]
  var data, code: seq[byte]

  if tx.isContractCreation:
    data = @[]
    code = tx.payload
  else:
    data = tx.payload
    code = vmState.readOnlyStateDB.getCode(tx.to).toSeq

  if gas < 0:
    debug "not enough gas to perform calculation", gas=gas
    return

  let msg = Message(
    kind: if tx.isContractCreation: evmcCreate else: evmcCall,
    depth: 0,
    gas: gas,
    gasPrice: tx.gasPrice,
    origin: sender,
    sender: sender,
    contractAddress: recipient,
    codeAddress: tx.to,
    value: tx.value,
    data: data,
    code: code
    )

  result = newComputation(vmState, msg, some(fork))
  doAssert result.isOriginComputation

proc execComputation*(c: Computation) =
  if c.msg.isCreate:
    c.applyMessage(Create)
  else:
    c.applyMessage(Call)

  c.vmState.mutateStateDB:
    var suicidedCount = 0
    for deletedAccount in c.accountsForDeletion:
      db.deleteAccount deletedAccount
      inc suicidedCount

    # FIXME: hook this into actual RefundSelfDestruct
    const RefundSelfDestruct = 24_000
    c.gasMeter.refundGas(RefundSelfDestruct * suicidedCount)

  if c.fork >= FkSpurious:
    c.collectTouchedAccounts()

  c.vmstate.status = c.isSuccess
  if c.isSuccess:
    c.vmState.addLogs(c.logEntries)

proc refundGas*(c: Computation, tx: Transaction, sender: EthAddress): GasInt =
  let
    gasRemaining = c.gasMeter.gasRemaining
    gasRefunded = c.getGasRefund()
    gasUsed = tx.gasLimit - gasRemaining
    gasRefund = min(gasRefunded, gasUsed div 2)

  c.vmState.mutateStateDB:
    db.addBalance(sender, (gasRemaining + gasRefund).u256 * tx.gasPrice.u256)

  result = gasUsed - gasRefund

#[
method executeTransaction(vmState: BaseVMState, transaction: Transaction): (Computation, BlockHeader) {.base.}=
  # Execute the transaction in the vm
  # TODO: introduced here: https://github.com/ethereum/py-evm/commit/21c57f2d56ab91bb62723c3f9ebe291d0b132dde
  # Refactored/Removed here: https://github.com/ethereum/py-evm/commit/cc991bf
  # Deleted here: https://github.com/ethereum/py-evm/commit/746defb6f8e83cee2c352a0ab8690e1281c4227c
  raise newException(ValueError, "Must be implemented by subclasses")


method addTransaction*(vmState: BaseVMState, transaction: Transaction, c: Computation, b: Block): (Block, Table[string, string]) =
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
    isStateless: bool): (Computation, Block, Table[string, string]) =
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