# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  options, sets,
  eth/common, chronicles, ./db/accounts_cache,
  transaction, vm_types, vm_state,
  ./vm/[computation, interpreter]

proc validateTransaction*(vmState: BaseVMState, tx: Transaction, sender: EthAddress, fork: Fork): bool =
  let balance = vmState.readOnlyStateDB.getBalance(sender)
  let nonce = vmState.readOnlyStateDB.getNonce(sender)

  if vmState.cumulativeGasUsed + tx.gasLimit > vmState.blockHeader.gasLimit:
    debug "invalid tx: block header gasLimit reached",
      maxLimit=vmState.blockHeader.gasLimit,
      gasUsed=vmState.cumulativeGasUsed,
      addition=tx.gasLimit
    return

  let totalCost = tx.gasLimit.u256 * tx.gasPrice.u256 + tx.value
  if totalCost > balance:
    debug "invalid tx: not enough cash",
      available=balance,
      require=totalCost
    return

  if tx.gasLimit < tx.intrinsicGas(fork):
    debug "invalid tx: not enough gas to perform calculation",
      available=tx.gasLimit,
      require=tx.intrinsicGas(fork)
    return

  if tx.accountNonce != nonce:
    debug "invalid tx: account nonce mismatch",
      txNonce=tx.accountnonce,
      accountNonce=nonce
    return

  result = true

proc setupComputation*(vmState: BaseVMState, tx: Transaction, sender: EthAddress, fork: Fork) : Computation =
  var gas = tx.gasLimit - tx.intrinsicGas(fork)
  assert gas >= 0

  vmState.setupTxContext(
    origin = sender,
    gasPrice = tx.gasPrice,
    forkOverride = some(fork)
  )

  let msg = Message(
    kind: if tx.isContractCreation: evmcCreate else: evmcCall,
    depth: 0,
    gas: gas,
    sender: sender,
    contractAddress: tx.getRecipient(),
    codeAddress: tx.to,
    value: tx.value,
    data: tx.payload
    )

  result = newComputation(vmState, msg)
  doAssert result.isOriginComputation

proc execComputation*(c: Computation) =
  if c.msg.isCreate:
    c.execCreate()
  else:
    c.vmState.mutateStateDB:
      db.incNonce(c.msg.sender)
    c.execCall()

  if c.isSuccess:
    c.refundSelfDestruct()
    shallowCopy(c.vmState.suicides, c.suicides)
    shallowCopy(c.vmState.logEntries, c.logEntries)
    c.vmState.touchedAccounts.incl c.touchedAccounts

  c.vmstate.status = c.isSuccess

proc refundGas*(c: Computation, tx: Transaction, sender: EthAddress) =
  let maxRefund = (tx.gasLimit - c.gasMeter.gasRemaining) div 2
  c.gasMeter.returnGas min(c.getGasRefund(), maxRefund)
  c.vmState.mutateStateDB:
    db.addBalance(sender, c.gasMeter.gasRemaining.u256 * tx.gasPrice.u256)

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