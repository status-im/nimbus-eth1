import
  ../logging, ../constants, ../errors, ../transaction, ../computation, "../block", ../vm_state, ../db/chain, ../utils/db, ../utils/header

type
  VM* = ref object of RootObj
    # The VM class represents the Chain rules for a specific protocol definition
    # such as the Frontier or Homestead network.  Defining an Chain  defining
    # individual VM classes for each fork of the protocol rules within that
    # network
    
    chainDB*: BaseChainDB
    isStateless*: bool
    state*: BaseVMState

proc newVM*(header: Header, chainDB: BaseChainDB): VM =
  new(result)
  result.chainDB = chainDB


method addTransaction*(vm: var VM, transaction: BaseTransaction, computation: BaseComputation): Block =
  # Add a transaction to the given block and save the block data into chaindb
  var receipt = self.state.makeReceipt(transaction, computation)
  var transactionIdx = len(vm.`block`.transactions)
  return Block()
  # var indexKey = rlp.encode(transaction_idx, sedes=rlp.sedes.big_endian_int)

  #       self.block.transactions.append(transaction)

  #       tx_root_hash = self.chaindb.add_transaction(self.block.header, index_key, transaction)
  #       receipt_root_hash = self.chaindb.add_receipt(self.block.header, index_key, receipt)

  #       self.block.bloom_filter |= receipt.bloom

  #       self.block.header.transaction_root = tx_root_hash
  #       self.block.header.receipt_root = receipt_root_hash
  #       self.block.header.bloom = int(self.block.bloom_filter)
  #       self.block.header.gas_used = receipt.gas_used

  #       return self.block

method applyTransaction*(vm: var VM, transaction: BaseTransaction): (BaseComputation, Block) =
  #  Apply the transaction to the vm in the current block
  if vm.isStateless:
    var (computation, b, trieData) = vm.state.applyTransaction(
      vm.state,
      transaction,
      vm.`block`,
      isStateless=true)
    vm.`block` = b
    result = (computation, b)
    # Persist changed transaction and receipt key-values to self.chaindb.
  else:
    var (computation, _, _) = vm.state.applyTransaction(
      vm.state,
      transaction,
      vm.`block`,
      isStateless=false)
    vm.addTransaction(transaction, computation)

    result = (computation, vm.`block`)

