import options, sets,
  eth/[common, bloom, trie/db], chronicles, nimcrypto,
  ../db/[db_chain, accounts_cache],
  ../utils, ../constants, ../transaction,
  ../vm_state, ../vm_types,
  ./dao, ./validate, ../config, ../forks,
  ../transaction/call_evm


proc processTransaction*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): GasInt =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  trace "Sender", sender
  trace "txHash", rlpHash = tx.rlpHash

  if validateTransaction(vmState, tx, sender, fork):
    result = txCallEvm(tx, sender, vmState, fork)

  vmState.cumulativeGasUsed += result

  let miner = vmState.coinbase()

  vmState.mutateStateDB:
    # miner fee
    let txFee = result.u256 * tx.gasPrice.u256
    db.addBalance(miner, txFee)

    for deletedAccount in vmState.selfDestructs:
      db.deleteAccount deletedAccount

    if fork >= FkSpurious:
      vmState.touchedAccounts.incl(miner)
      # EIP158/161 state clearing
      for account in vmState.touchedAccounts:
        if db.accountExists(account) and db.isEmptyAccount(account):
          debug "state clearing", account
          db.deleteAccount(account)

  if vmState.generateWitness:
    vmState.accountDb.collectWitnessData()
  vmState.accountDb.persist(clearCache = false)

type
  # TODO: these types need to be removed
  # once eth/bloom and eth/common sync'ed
  Bloom = common.BloomFilter
  LogsBloom = bloom.BloomFilter

# TODO: move these three receipt procs below somewhere else more appropriate
func logsBloom(logs: openArray[Log]): LogsBloom =
  for log in logs:
    result.incl log.address
    for topic in log.topics:
      result.incl topic

func createBloom*(receipts: openArray[Receipt]): Bloom =
  var bloom: LogsBloom
  for rec in receipts:
    bloom.value = bloom.value or logsBloom(rec.logs).value
  result = bloom.value.toByteArrayBE

proc makeReceipt*(vmState: BaseVMState, fork: Fork, txType: TxType): Receipt =
  var rec: Receipt
  if fork < FkByzantium:
    rec.isHash = true
    rec.hash   = vmState.accountDb.rootHash
  else:
    rec.isHash = false
    rec.status = vmState.status

  rec.receiptType = txType
  rec.cumulativeGasUsed = vmState.cumulativeGasUsed
  rec.logs = vmState.getAndClearLogEntries()
  rec.bloom = logsBloom(rec.logs).value.toByteArrayBE
  rec

func eth(n: int): Uint256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth
  blockRewards*: array[Fork, Uint256] = [
    eth5, # FkFrontier
    eth5, # FkHomestead
    eth5, # FkTangerine
    eth5, # FkSpurious
    eth3, # FkByzantium
    eth2, # FkConstantinople
    eth2, # FkPetersburg
    eth2, # FkIstanbul
    eth2, # FkBerlin
    eth2  # FkLondon
  ]

proc calculateReward(fork: Fork, header: BlockHeader, body: BlockBody, vmState: BaseVMState) =
  # PoA consensus engine have no reward for miner
  if vmState.consensusEnginePoA: return

  let blockReward = blockRewards[fork]
  var mainReward = blockReward

  for uncle in body.uncles:
    var uncleReward = uncle.blockNumber.u256 + 8.u256
    uncleReward -= header.blockNumber.u256
    uncleReward = uncleReward * blockReward
    uncleReward = uncleReward div 8.u256
    vmState.mutateStateDB:
      db.addBalance(uncle.coinbase, uncleReward)
    mainReward += blockReward div 32.u256

  vmState.mutateStateDB:
    db.addBalance(header.coinbase, mainReward)

proc processBlock*(chainDB: BaseChainDB, header: BlockHeader, body: BlockBody, vmState: BaseVMState): ValidationResult =
  var dbTx = chainDB.db.beginTransaction()
  defer: dbTx.dispose()

  if chainDB.config.daoForkSupport and header.blockNumber == chainDB.config.daoForkBlock:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot", blockNumber=header.blockNumber
    return ValidationResult.Error

  let fork = chainDB.config.toFork(vmState.blockNumber)

  if header.txRoot != BLANK_ROOT_HASH:
    if body.transactions.len == 0:
      debug "No transactions in body", blockNumber=header.blockNumber
      return ValidationResult.Error
    else:
      trace "Has transactions", blockNumber = header.blockNumber, blockHash = header.blockHash

      vmState.receipts = newSeq[Receipt](body.transactions.len)
      vmState.cumulativeGasUsed = 0
      for txIndex, tx in body.transactions:
        var sender: EthAddress
        if tx.getSender(sender):
          discard processTransaction(tx, sender, vmState, fork)
        else:
          debug "Could not get sender", txIndex, tx
          return ValidationResult.Error
        vmState.receipts[txIndex] = makeReceipt(vmState, fork, tx.txType)

  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = chainDB.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return ValidationResult.Error

  calculateReward(fork, header, body, vmState)

  # Reward beneficiary
  vmState.mutateStateDB:
    if vmState.generateWitness:
      db.collectWitnessData()
    db.persist(ClearCache in vmState.flags)

  let stateDb = vmState.accountDb
  if header.stateRoot != stateDb.rootHash:
    debug "wrong state root in block", blockNumber=header.blockNumber, expected=header.stateRoot, actual=stateDb.rootHash, arrivedFrom=chainDB.getCanonicalHead().stateRoot
    return ValidationResult.Error

  let bloom = createBloom(vmState.receipts)
  if header.bloom != bloom:
    debug "wrong bloom in block", blockNumber=header.blockNumber
    return ValidationResult.Error

  let receiptRoot = calcReceiptRoot(vmState.receipts)
  if header.receiptRoot != receiptRoot:
    debug "wrong receiptRoot in block", blockNumber=header.blockNumber, actual=receiptRoot, expected=header.receiptRoot
    return ValidationResult.Error

  # `applyDeletes = false`
  # If the trie pruning activated, each of the block will have its own state trie keep intact,
  # rather than destroyed by trie pruning. But the current block will still get a pruned trie.
  # If trie pruning deactivated, `applyDeletes` have no effects.
  dbTx.commit(applyDeletes = false)


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
