import options, sets,
  eth/[common, bloom, trie/db], chronicles, nimcrypto,
  ../db/[db_chain, accounts_cache],
  ../utils, ../constants, ../transaction,
  ../vm_state, ../vm_types, ../vm_state_transactions,
  ../vm/[computation, message],
  ../vm/interpreter/vm_forks,
  ./dao, ../config

proc processTransaction*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): GasInt =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  trace "Sender", sender
  trace "txHash", rlpHash = tx.rlpHash

  if validateTransaction(vmState, tx, sender, fork):
    var c = setupComputation(vmState, tx, sender, fork)
    vmState.mutateStateDB:
      db.subBalance(sender, tx.gasLimit.u256 * tx.gasPrice.u256)
    execComputation(c)

    result = tx.gasLimit
    if not c.shouldBurnGas:
      c.refundGas(tx, sender)
      result -= c.gasMeter.gasRemaining

  vmState.cumulativeGasUsed += result

  let miner = vmState.coinbase()

  vmState.mutateStateDB:
    # miner fee
    let txFee = result.u256 * tx.gasPrice.u256
    db.addBalance(miner, txFee)

    for deletedAccount in vmState.suicides:
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
  for receipt in receipts:
    bloom.value = bloom.value or logsBloom(receipt.logs).value
  result = bloom.value.toByteArrayBE

proc makeReceipt*(vmState: BaseVMState, fork = FkFrontier): Receipt =
  if fork < FkByzantium:
    result.stateRootOrStatus = hashOrStatus(vmState.accountDb.rootHash)
  else:
    result.stateRootOrStatus = hashOrStatus(vmState.status)

  result.cumulativeGasUsed = vmState.cumulativeGasUsed
  result.logs = vmState.getAndClearLogEntries()
  result.bloom = logsBloom(result.logs).value.toByteArrayBE

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
    eth2  # FkBerlin
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
        vmState.receipts[txIndex] = makeReceipt(vmState, fork)

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
    when defined(geth):
      error "Wrong state root in block", blockNumber=header.blockNumber, expected=header.stateRoot, actual=stateDb.rootHash
    else:
      error "Wrong state root in block", blockNumber=header.blockNumber, expected=header.stateRoot, actual=stateDb.rootHash, arrivedFrom=chainDB.getCanonicalHead().stateRoot
    # this one is a show stopper until we are confident in our VM's
    # compatibility with the main chain
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
