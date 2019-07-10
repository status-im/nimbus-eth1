import options, sets,
  eth/[common, bloom], stew/ranges, chronicles, nimcrypto,
  ../db/[db_chain, state_db],
  ../utils, ../constants, ../transaction,
  ../vm_state, ../vm_types, ../vm_state_transactions,
  ../vm/[computation, message],
  ../vm/interpreter/vm_forks,
  ./dao

proc processTransaction*(tx: Transaction, sender: EthAddress, vmState: BaseVMState, fork: Fork): GasInt =
  ## Process the transaction, write the results to db.
  ## Returns amount of ETH to be rewarded to miner
  trace "Sender", sender
  trace "txHash", rlpHash = tx.rlpHash

  if fork >= FkSpurious:
    vmState.touchedAccounts.incl(vmState.blockHeader.coinbase)

  var gasUsed = tx.gasLimit

  block:
    if vmState.cumulativeGasUsed + gasUsed > vmState.blockHeader.gasLimit:
      debug "invalid tx: block header gasLimit reached",
        blockGasLimit=vmState.blockHeader.gasLimit,
        gasUsed=gasUsed,
        txGasLimit=tx.gasLimit
      gasUsed = 0
      break

    let upfrontGasCost = tx.gasLimit.u256 * tx.gasPrice.u256
    var balance = vmState.readOnlyStateDb().getBalance(sender)
    if balance < upfrontGasCost: break

    let recipient = tx.getRecipient()
    let isCollision = vmState.readOnlyStateDb().hasCodeOrNonce(recipient)

    var computation = setupComputation(vmState, tx, sender, recipient, fork)
    if computation.isNil: # OOG in setupComputation
      gasUsed = 0
      break

    vmState.mutateStateDB:
      db.incNonce(sender)
      db.subBalance(sender, upfrontGasCost)

    if tx.isContractCreation and isCollision: break
    execComputation(computation)
    if not computation.shouldBurnGas:
      gasUsed = computation.refundGas(tx, sender)

    if computation.isSuicided(vmState.blockHeader.coinbase):
      gasUsed = 0

  vmState.cumulativeGasUsed += gasUsed

  # miner fee
  let txFee = gasUsed.u256 * tx.gasPrice.u256
  vmState.mutateStateDB:
    db.addBalance(vmState.blockHeader.coinbase, txFee)

    # EIP158 state clearing
    for account in vmState.touchedAccounts:
      if db.accountExists(account) and db.isEmptyAccount(account):
        debug "state clearing", account
        db.deleteAccount(account)

  result = gasUsed

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

proc makeReceipt(vmState: BaseVMState, fork = FkFrontier): Receipt =
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
  blockRewards: array[Fork, Uint256] = [
    eth5, # FkFrontier
    eth5, # FkThawing
    eth5, # FkHomestead
    eth5, # FkDao
    eth5, # FkTangerine
    eth5, # FkSpurious
    eth3, # FkByzantium
    eth2  # FkConstantinople
  ]

proc processBlock*(chainDB: BaseChainDB, header: BlockHeader, body: BlockBody, vmState: BaseVMState): ValidationResult =
  if chainDB.config.daoForkSupport and header.blockNumber == chainDB.config.daoForkBlock:
    vmState.mutateStateDB:
      db.applyDAOHardFork()

  if body.transactions.calcTxRoot != header.txRoot:
    debug "Mismatched txRoot", blockNumber=header.blockNumber
    return ValidationResult.Error

  let fork = vmState.blockNumber.toFork

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
          let gasUsed = processTransaction(tx, sender, vmState, fork)
        else:
          debug "Could not get sender", txIndex, tx
          return ValidationResult.Error
        vmState.receipts[txIndex] = makeReceipt(vmState, fork)

  let blockReward = blockRewards[fork]
  var mainReward = blockReward
  if header.ommersHash != EMPTY_UNCLE_HASH:
    let h = chainDB.persistUncles(body.uncles)
    if h != header.ommersHash:
      debug "Uncle hash mismatch"
      return ValidationResult.Error
    for uncle in body.uncles:
      var uncleReward = uncle.blockNumber.u256 + 8.u256
      uncleReward -= header.blockNumber.u256
      uncleReward = uncleReward * blockReward
      uncleReward = uncleReward div 8.u256
      vmState.mutateStateDB:
        db.addBalance(uncle.coinbase, uncleReward)
      mainReward += blockReward div 32.u256

  # Reward beneficiary
  vmState.mutateStateDB:
    db.addBalance(header.coinbase, mainReward)

  let stateDb = vmState.accountDb
  if header.stateRoot != stateDb.rootHash:
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
